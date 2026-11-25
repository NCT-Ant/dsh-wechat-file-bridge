/**
 * dsh-wechat-bridge -- Host half.
 *
 * Bridges DeepSeek Harness to the WeChat desktop client's "file transfer
 * helper" (文件传输助手) chat, so files and messages can move between this
 * machine and the phone that is logged into the same WeChat account.
 *
 * Why a PowerShell driver: the WeChat 4.x client is a Qt application with a
 * self-drawn UI. It exposes no UI Automation tree and ignores posted key
 * messages, so the only way to send is a real foreground window plus injected
 * input. Receiving, on the other hand, needs no UI at all: WeChat already
 * writes every downloaded file into
 *   %USERPROFILE%\Documents\xwechat_files\<wxid>\msg\file\<YYYY-MM>\
 * and that keeps working while the screen is locked.
 */
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const here = path.dirname(fileURLToPath(import.meta.url))
const scriptPath = path.join(here, 'assets', 'WechatBridge.ps1')
const DEFAULT_CHAT = '文件传输助手'
const TIMEOUT_MS = 45_000
const STATE_DIR = path.join(os.tmpdir(), 'dsh-wechat-bridge')
const OUTBOX_FILE = path.join(STATE_DIR, 'outbox.json')
const OUTBOX_POLL_MS = 120_000
// A queued send may only be replayed once the user has been away this long:
// replaying steals the foreground, so doing it while they are working is rude.
const IDLE_REPLAY_MIN_SEC = 300

// A locked workstation cannot be driven by injected input, so sends made while
// the screen is locked are parked here and replayed once the desktop unlocks.
function readOutbox() {
  try {
    const parsed = JSON.parse(fs.readFileSync(OUTBOX_FILE, 'utf8'))
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

function writeOutbox(list) {
  fs.mkdirSync(STATE_DIR, { recursive: true })
  fs.writeFileSync(OUTBOX_FILE, JSON.stringify(list, null, 2), 'utf8')
}

function runBridge(request) {
  return new Promise((resolve, reject) => {
    const child = spawn('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy', 'Bypass',
      '-File', scriptPath,
    ], { windowsHide: true })

    let stdout = ''
    let stderr = ''
    const timer = setTimeout(() => {
      child.kill()
      reject(new Error('wechat_bridge: bridge script timed out'))
    }, TIMEOUT_MS)

    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')
    child.stdout.on('data', (chunk) => { stdout += chunk })
    child.stderr.on('data', (chunk) => { stderr += chunk })
    child.on('error', (error) => { clearTimeout(timer); reject(error) })
    child.on('close', (code) => {
      clearTimeout(timer)
      const text = stdout.trim()
      const lastLine = text.split(/\r?\n/).filter(Boolean).pop() ?? ''
      if (!lastLine.startsWith('{')) {
        reject(new Error(`wechat_bridge: no JSON from bridge (exit ${code})${stderr ? `: ${stderr.trim()}` : ''}`))
        return
      }
      try {
        resolve(JSON.parse(lastLine))
      } catch (error) {
        reject(new Error(`wechat_bridge: bad JSON from bridge: ${error.message}`))
      }
    })

    // Windows PowerShell 5.1 decodes piped stdin with the ANSI code page, so a
    // UTF-8 chat name would arrive as mojibake and the send would silently target
    // whatever chat was already open. JSON \uXXXX escapes are pure ASCII and
    // survive any code page.
    const payload = JSON.stringify(request ?? {}).replace(/[\u007f-\uffff]/g, (ch) =>
      `\\u${ch.charCodeAt(0).toString(16).padStart(4, '0')}`)
    child.stdin.write(payload, 'ascii')
    child.stdin.end()
  })
}

function describeStatus(v) {
  if (!v.ok) return '微信没有在运行。'
  const lines = [
    `微信 ${v.version ?? '?'} · 进程 ${v.processCount} 个 · ${v.locked ? '当前锁屏' : '未锁屏'}`,
    `账号目录：${v.accountDir ?? '未找到'}`,
    `收件目录：${v.inboxDir ?? '未找到'}`,
    v.canSend ? '发送通道：可用' : `发送通道：不可用${v.locked ? '（锁屏中，发件会先排队）' : ''}`,
  ]
  return lines.join('\n')
}

let outboxTimer = null
let flushing = false

function stopOutboxTimer() {
  if (outboxTimer) {
    clearInterval(outboxTimer)
    outboxTimer = null
  }
}

function startOutboxTimer() {
  if (outboxTimer) return
  outboxTimer = setInterval(() => {
    flushOutbox().catch(() => {})
  }, OUTBOX_POLL_MS)
  outboxTimer.unref?.()
}

async function flushOutbox() {
  if (flushing) return
  const pending = readOutbox()
  if (pending.length === 0) {
    stopOutboxTimer()
    return
  }
  // Replaying means driving WeChat's UI, which yanks the foreground away from
  // whoever is using the machine. Only do it once the user has actually stepped
  // away; otherwise leave the queue untouched and check again later.
  try {
    const st = await runBridge({ action: 'status' })
    if (st?.ok && typeof st.idleSec === 'number' && st.idleSec < IDLE_REPLAY_MIN_SEC) {
      return
    }
  } catch {}
  flushing = true
  const remaining = []
  try {
    for (const item of pending) {
      const res = await runBridge({
        action: item.action,
        chat: item.chat,
        text: item.text,
        path: item.path,
      })
      if (res?.queued || res?.locked || !res?.ok) {
        // Still locked (or failed) -- keep this one and everything after it.
        remaining.push(item)
        remaining.push(...pending.slice(pending.indexOf(item) + 1))
        break
      }
    }
    writeOutbox(remaining)
    if (remaining.length === 0) stopOutboxTimer()
  } finally {
    flushing = false
  }
}

function describeFiles(v) {
  if (!v.ok) return v.message ?? '读取失败'
  if (!v.files || v.files.length === 0) return '最近没有新的接收文件。'
  const lines = v.files.map((f, i) => `${i + 1}. ${f.name} · ${f.sizeText} · ${f.receivedAt}`)
  return [`收件目录：${v.inboxDir}`, ...lines].join('\n')
}

function describeSend(v) {
  if (!v.ok) return v.error ?? v.message ?? '发送失败'
  if (v.path) return `已把文件发到「${v.chat}」：${v.path}`
  return `已把 ${v.textLength} 字的文本发到「${v.chat}」`
}

export const inject = ['tools']

export function apply(ctx) {
  ctx.effect(() => {
    const dispose = ctx.tools.register({
      name: 'wechat_bridge',
      description:
        'Bridge to the WeChat desktop client through the "file transfer helper" chat, so files/messages can move between this computer and the phone. '
        + 'action="status" reports whether WeChat is running, whether the screen is locked, and whether sending is possible right now. '
        + 'action="list" lists the newest files WeChat downloaded from any chat (path, size, received time) — this works even while the screen is locked. '
        + 'action="snapshot" captures the current WeChat window to a PNG so you can look at the conversation. '
        + 'action="send_text" sends a text message (args: text, optional chat) and action="send_file" sends one file (args: path, optional chat) to the helper chat; '
        + 'sending needs an unlocked desktop because WeChat 4.x exposes no automation API and must be driven through the foreground window. '
        + 'When the screen is locked a send is parked in an outbox and replayed automatically after unlock (action="outbox" shows it). '
        + 'Call this when the user wants to pull a file that was sent from their phone, push a file or a result to their phone, or check whether the WeChat channel is usable.',
      parameters: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ['status', 'list', 'snapshot', 'send_text', 'send_file', 'outbox'],
            description: 'status = channel health; list = newest received files; snapshot = screenshot; send_text / send_file = push to WeChat; outbox = sends waiting for unlock.',
          },
          text: { type: 'string', description: 'Message body for send_text.' },
          path: { type: 'string', description: 'Absolute file path for send_file.' },
          chat: { type: 'string', description: 'Target chat name; defaults to 文件传输助手.' },
          limit: { type: 'number', description: 'For list: how many files to return (default 20).' },
          sinceDays: { type: 'number', description: 'For list: only files received within the last N days.' },
        },
        required: ['action'],
        additionalProperties: false,
      },
      output: {
        schema: {
          type: 'object',
          properties: {
            ok: { type: 'boolean' },
            path: { type: 'string' },
            error: { type: 'string' },
            message: { type: 'string' },
          },
          additionalProperties: true,
        },
        render: (args, value) => {
          const v = value ?? {}
          const action = args?.action ?? 'status'
          let text
          if (action === 'list') text = describeFiles(v)
          else if (action === 'send_text' || action === 'send_file') text = describeSend(v)
          else if (action === 'snapshot') text = v.ok ? `微信窗口截图：${v.path}` : (v.message ?? '截图失败')
          else if (action === 'focus') text = v.ok ? '微信窗口已切到前台。' : (v.message ?? '无法切到前台')
          else if (action === 'outbox') {
            text = v.pending > 0
              ? `待发队列 ${v.pending} 条：\n${(v.items ?? []).map((i, n) => `${n + 1}. ${i.path ?? i.text ?? ''} · ${i.queuedAt}`).join('\n')}`
              : '待发队列是空的。'
          } else text = describeStatus(v)
          return [{ type: 'text', text }]
        },
      },
      async execute(args) {
        if (process.platform !== 'win32') {
          throw new Error('wechat_bridge: only Windows is supported')
        }
        const input = args && typeof args === 'object' ? args : {}
        const rawAction = input.action ?? 'status'
        // The wire format uses snake_case; the PowerShell driver uses dashes.
        const action = String(rawAction).replace(/_/g, '-')

        if (action === 'outbox') {
          const list = readOutbox()
          return { ok: true, action, pending: list.length, items: list }
        }

        const request = {
          action,
          chat: input.chat || DEFAULT_CHAT,
          text: input.text,
          path: input.path,
          limit: input.limit,
          sinceDays: input.sinceDays,
        }
        const value = await runBridge(request)

        // A locked desktop cannot receive injected input: park the send and let
        // the timer replay it once the user unlocks.
        if (value?.locked && (action === 'send-file' || action === 'send-text')) {
          const outbox = readOutbox()
          outbox.push({
            action,
            chat: request.chat,
            text: request.text,
            path: request.path,
            queuedAt: new Date().toISOString(),
          })
          writeOutbox(outbox)
          startOutboxTimer()
          return {
            ok: false,
            queued: true,
            locked: true,
            needsUnlock: true,
            sent: false,
            action,
            pending: outbox.length,
            message:
              `电脑正锁屏：这条${action === 'send-file' ? '文件' : '消息'}**还没有发出去**，` +
              `已存进待发队列（共 ${outbox.length} 条）。解锁后每 2 分钟检查一次并自动补发，` +
              `补发前会先校验当前会话名，对不上就中止、绝不发往别的会话。`,
          }
        }

        if (!value?.locked) {
          // Opportunistic: any successful call is a good moment to drain the outbox.
          flushOutbox().catch(() => {})
        }
        return { ...value, action }
      },
    })
    if (readOutbox().length > 0) startOutboxTimer()
    return () => {
      stopOutboxTimer()
      if (typeof dispose === 'function') dispose()
    }
  })
}
