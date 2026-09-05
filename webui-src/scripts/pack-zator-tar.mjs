// Сборка единого архива развёртывания zator-контента: zator-deploy.tar.gz.
//
// Пути внутри архива относительно $ZATOR_ROOT (/opt/zator) и зеркалируют
// карту развёртывания z2r.sh (get_repo + webui_install_files) — держать
// синхронно с ним. Архив НЕ содержит runtime-состояние: extra_strats/cache
// (кроме locked.lua, который z2r.sh обновляет из репозитория) и
// lists/autohostlist.txt (копится на устройстве).
//
// Файлы читаются из рабочего дерева; текстовые нормализуются в LF (включая
// блобы, исторически закоммиченные с CRLF), бинарники (.bin и файлы с NUL)
// не трогаются. Права: 0755 у исполняемых, 0644 у остальных, каталоги 0755.
// Заголовки tar: uid/gid 0, mtime 0 — сборка детерминирована.
//
// Запуск: npm run pack (в webui-src). Результат в webui-src/dist/:
//   zator-deploy.tar.gz       — архив
//   zator-deploy.sha256       — чексумма в формате sha256sum -c
//   zator-deploy.manifest.json — список файлов с sha256 нормализованного контента
//
// Порядок развёртывания на устройстве (пока НЕ встроен в z2r.sh):
//   1. скачать архив, проверить магию gzip (1f 8b, у busybox od -b: "037 213")
//      и gzip -t — на случай 403/404-страницы, сохранённой как .tar.gz;
//   2. сверить sha256 (zator-deploy.sha256, busybox sha256sum -c);
//   3. распаковать во временную директорию /tmp (tmpfs) и заменить файлы
//      в $ZATOR_ROOT; runtime-состояние (extra_strats/cache кроме locked.lua,
//      lists/autohostlist.txt) архивом не затрагивается;
//   4. повторить webui_fix_interpreters из z2r.sh: шебанг в репозитории
//      портабельный (#!/usr/bin/env bash), на Keenetic нужен #!/opt/bin/bash;
//   5. перезапустить webui (run-webui.sh restart).

import { gzipSync } from 'node:zlib'
import { readFileSync, writeFileSync, mkdirSync, readdirSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execSync } from 'node:child_process'

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const outDir = join(repoRoot, 'webui-src', 'dist')

// Z2R_LIB_FILES из z2r.sh: repo lib/ -> $ZATOR_ROOT/z2r_lib
const Z2R_LIB_FILES = [
  'ui.sh', 'provider.sh', 'telemetry.sh', 'recommendations.sh', 'netcheck.sh',
  'premium.sh', 'strategies.sh', 'submenus.sh', 'actions.sh', 'config.sh',
  'orchestra_state.sh',
]

// repo lists/ -> $ZATOR_ROOT/lists (список из get_repo + netrogat_substrings);
// autohostlist.txt не упаковываем — runtime-файл устройства
const LISTS = [
  'cloudflare-ipset.txt', 'cloudflare-ipset_v6.txt', 'netrogat.txt',
  'netrogat_substrings.txt', 'russia-discord.txt', 'russia-youtube-rtmps.txt',
  'russia-youtube.txt', 'russia-youtubeQ.txt', 'tg_cidr.txt',
]

// repo extra_strats/ (вложенные) -> плоские имена из get_repo
const EXTRA_STRATS = [
  ['extra_strats/UDP/YT/List.txt', 'extra_strats/UDP_YT_list.txt'],
  ['extra_strats/TCP/RKN/List.txt', 'extra_strats/TCP_RKN_list.txt'],
  ['extra_strats/TCP/RKN/Custom.txt', 'extra_strats/TCP_Custom.txt'],
  ['extra_strats/TCP/YT/List.txt', 'extra_strats/TCP_YT_list.txt'],
  ['extra_strats/TCP/RKN/Discord.txt', 'extra_strats/TCP_Discord.txt'],
  ['extra_strats/TCP/RKN/Domains_By_Substring.txt', 'extra_strats/TCP_RKN_domains_by_substring.txt'],
]

// фейки идут единым файлом fake/* -> $ZATOR_ROOT/files/fake
const FAKE_DIR = 'fake'
const FAKE_TARGET = 'files/fake'

// webui: только устанавливаемое (webui_install_files), без dev/
const webuiCgi = readdirSync(join(repoRoot, 'webui', 'cgi-bin')).sort()

// [путь в архиве, путь в репо, исполняемый?]
const files = [
  ...Z2R_LIB_FILES.map((name) => [`z2r_lib/${name}`, `lib/${name}`, false]),
  ...readdirSync(join(repoRoot, 'lua')).sort().map((name) => [`lua/${name}`, `lua/${name}`, name === 'strategy-validator.sh']),
  ...LISTS.map((name) => [`lists/${name}`, `lists/${name}`, false]),
  ...EXTRA_STRATS.map(([from, to]) => [to, from, false]),
  ['extra_strats/cache/orchestra/locked.lua', 'orchestra/locked.lua', false],
  ['webui/run-webui.sh', 'webui/run-webui.sh', true],
  ...webuiCgi.map((name) => [`webui/cgi-bin/${name}`, `webui/cgi-bin/${name}`, true]),
  ['webui/www/index.html', 'webui/index.html', false],
  ['webui/www/styles.css', 'webui/styles.css', false],
  ['webui/www/app.js', 'webui/app.js', false],
  ['webui/www/favicon.svg', 'webui/favicon.svg', false],
  ['firewall/client-scope-iptables.sh', 'firewall/client-scope-iptables.sh', true],
  ['firewall/client-scope-nft.sh', 'firewall/client-scope-nft.sh', true],
  ['data/providers/asn.txt', 'data/providers/asn.txt', false],
]

for (const name of readdirSync(join(repoRoot, FAKE_DIR)).sort()) {
  files.push([`${FAKE_TARGET}/${name}`, `${FAKE_DIR}/${name}`, false])
}

function isBinary(buf) {
  return buf.subarray(0, 8192).includes(0)
}

function readDeployContent(repoPath) {
  const raw = readFileSync(join(repoRoot, repoPath))
  if (isBinary(raw)) return raw
  return Buffer.from(raw.toString('utf8').replace(/\r\n/g, '\n'), 'utf8')
}

// --- минимальный ustar-писатель (без внешних зависимостей) ---

function octal(value, length) {
  const str = value.toString(8).padStart(length - 1, '0')
  return `${str}\0`
}

function splitName(name) {
  if (name.length <= 100) return { name, prefix: '' }
  const slash = name.lastIndexOf('/', name.length - 101)
  if (slash < 0) throw new Error(`слишком длинный путь: ${name}`)
  return { name: name.slice(slash + 1), prefix: name.slice(0, slash) }
}

function tarHeader(entry) {
  const head = Buffer.alloc(512)
  const { name, prefix } = splitName(entry.name)
  head.write(name, 0)
  head.write(octal(entry.mode ?? 0o644, 8), 100)
  head.write(octal(0, 8), 108) // uid
  head.write(octal(0, 8), 116) // gid
  head.write(octal(entry.size ?? 0, 12), 124)
  head.write(octal(0, 12), 136) // mtime
  head.write('        ', 148) // чексумма-заглушка
  head.write(entry.type, 156)
  if (entry.linkname) head.write(entry.linkname, 157)
  head.write('ustar\0', 257)
  head.write('00', 263)
  head.write('root', 265)
  head.write('root', 297)
  if (prefix) head.write(prefix, 345)
  let sum = 0
  for (const byte of head) sum += byte
  head.write(`${sum.toString(8).padStart(6, '0')}\0 `, 148)
  return head
}

function tarEntry(entry) {
  const blocks = [tarHeader(entry)]
  if (entry.body) {
    blocks.push(entry.body)
    const tail = (512 - (entry.body.length % 512)) % 512
    if (tail) blocks.push(Buffer.alloc(tail))
  }
  return Buffer.concat(blocks)
}

// --- сборка ---

const dirs = new Set()
for (const [archivePath] of files) {
  let dir = dirname(archivePath)
  while (dir && dir !== '.') {
    dirs.add(dir)
    dir = dirname(dir)
  }
}

const entries = []
for (const dir of [...dirs].sort()) {
  entries.push(tarEntry({ name: `${dir}/`, type: '5', mode: 0o755 }))
}
const manifest = { generatedBy: 'pack-zator-tar.mjs', commit: '', entries: [] }
try {
  manifest.commit = execSync('git rev-parse --short HEAD', { cwd: repoRoot }).toString().trim()
} catch {
  manifest.commit = 'unknown'
}
for (const [archivePath, repoPath, executable] of files) {
  const body = readDeployContent(repoPath)
  const sha = createHash('sha256').update(body).digest('hex')
  manifest.entries.push({ path: archivePath, sha256: sha, size: body.length })
  entries.push(tarEntry({ name: archivePath, type: '0', mode: executable ? 0o755 : 0o644, size: body.length, body }))
}
// симлинк www/cgi-bin -> ../cgi-bin, как в webui_install_files
entries.push(tarEntry({ name: 'webui/www/cgi-bin', type: '2', mode: 0o777, linkname: '../cgi-bin' }))

let tar = Buffer.concat(entries)
// корректное завершение: два нулевых блока + добивка до размера записи 10240
tar = Buffer.concat([tar, Buffer.alloc(10240 - ((tar.length + 1024) % 10240) + 1024)])

const gz = gzipSync(tar, { mtime: 0 })
mkdirSync(outDir, { recursive: true })
const gzPath = join(outDir, 'zator-deploy.tar.gz')
writeFileSync(gzPath, gz)
writeFileSync(join(outDir, 'zator-deploy.sha256'), `${createHash('sha256').update(gz).digest('hex')}  zator-deploy.tar.gz\n`)
writeFileSync(join(outDir, 'zator-deploy.manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`)

console.log(`commit: ${manifest.commit}`)
console.log(`files: ${manifest.entries.length} + symlink webui/www/cgi-bin, dirs: ${dirs.size}`)
console.log(`tar: ${(tar.length / 1024).toFixed(0)} KB, gz: ${(gz.length / 1024).toFixed(0)} KB`)
console.log(`sha256: ${createHash('sha256').update(gz).digest('hex')}`)
console.log(`out: ${gzPath}`)
