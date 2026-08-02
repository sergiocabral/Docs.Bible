'use strict'

/* eslint-disable @typescript-eslint/no-require-imports */

const { posix: path } = require('node:path')

const ENABLE_ATTRIBUTE = 'page-bible-navigation'
const GENERATED_MARKER = '// generated:bible-navigation'

function hasAttribute (componentVersion, name) {
  const attributes = componentVersion.asciidoc?.attributes || {}
  return Object.prototype.hasOwnProperty.call(attributes, name)
}

function splitTarget (value) {
  const hashIndex = value.indexOf('#')
  return hashIndex === -1
    ? { page: value, fragment: '' }
    : { page: value.slice(0, hashIndex), fragment: value.slice(hashIndex) }
}

function extractNavigationTable (file, contentCatalog) {
  const lines = file.contents.toString().split(/\r?\n/)
  const delimiterIndex = lines.findIndex(
    (line, index) => line.trim() === '|===' && /^\[cols=/.test(lines[index - 1]?.trim())
  )
  if (delimiterIndex === -1) return null

  const cells = []
  for (let index = delimiterIndex + 1; index < lines.length; index += 1) {
    const line = lines[index].trim()
    if (line === '|===') break
    if (!line.startsWith('|')) continue
    if (line === '|') {
      cells.push(null)
      continue
    }

    const match = line.match(/^\|\s*xref:([^\[]+)\[([^\]]*)\]\s*$/)
    if (!match) continue
    const { page, fragment } = splitTarget(match[1])
    const target = contentCatalog.resolvePage(page, file.src)
    if (!target) return null
    cells.push({ fragment, label: match[2], target })
  }
  return cells.length ? cells : null
}

function renderNavigationTable (cells, role) {
  const lines = [
    `[cols="8*^",role="bible-navigation ${role}"]`,
    '|===',
  ]
  for (const cell of cells) {
    if (!cell) {
      lines.push('|')
      continue
    }
    const { component, module: moduleName, relative, version } = cell.target.src
    const versionPrefix = version ? `${version}@` : ''
    const componentPrefix = `${versionPrefix}${component}:`
    lines.push(
      `| xref:${componentPrefix}${moduleName}:${relative}${cell.fragment}[${cell.label}]`
    )
  }
  lines.push('|===')
  return lines.join('\n')
}

function injectAfterHeader (file, navigation) {
  const source = file.contents.toString()
  if (source.includes(GENERATED_MARKER)) return false

  const newline = source.includes('\r\n') ? '\r\n' : '\n'
  const lines = source.split(/\r?\n/)
  const titleIndex = lines.findIndex((line) => /^=\s+\S/.test(line))
  if (titleIndex === -1) return false

  let insertionIndex = lines.findIndex(
    (line, index) => index > titleIndex && line.trim() === ''
  )
  if (insertionIndex === -1) insertionIndex = lines.length
  else insertionIndex += 1

  lines.splice(insertionIndex, 0, GENERATED_MARKER, navigation, '')
  file.contents = Buffer.from(lines.join(newline))
  return true
}

function enhanceModule (pages, contentCatalog) {
  const byRelative = new Map(pages.map((page) => [page.src.relative, page]))
  const editionIndex = byRelative.get('index.adoc')
  if (!editionIndex) return 0

  const books = extractNavigationTable(editionIndex, contentCatalog)
  if (!books) return 0
  const booksTable = renderNavigationTable(books, 'bible-navigation-books')
  const chapterTables = new Map()
  for (const [relative, page] of byRelative) {
    if (path.basename(relative) !== 'index.adoc') continue
    const dirname = path.dirname(relative)
    if (dirname === '.' || !/^\d{3}-/.test(dirname)) continue
    const chapters = extractNavigationTable(page, contentCatalog)
    if (chapters) chapterTables.set(dirname, chapters)
  }
  let enhanced = 0

  for (const page of pages) {
    const dirname = path.dirname(page.src.relative)
    if (dirname === '.' || !/^\d{3}-/.test(dirname)) continue

    const bookIndex = byRelative.get(path.join(dirname, 'index.adoc'))
    if (!bookIndex) continue
    if (page === bookIndex) {
      if (injectAfterHeader(page, booksTable)) enhanced += 1
      continue
    }

    const chapters = chapterTables.get(dirname)
    if (!chapters) continue
    const chaptersTable = renderNavigationTable(
      chapters,
      'bible-navigation-chapters'
    )
    if (injectAfterHeader(page, `${booksTable}\n\n${chaptersTable}`)) enhanced += 1
  }
  return enhanced
}

function enhanceBibleNavigation (contentCatalog) {
  let enhanced = 0
  for (const component of contentCatalog.getComponents()) {
    for (const componentVersion of component.versions) {
      if (!hasAttribute(componentVersion, ENABLE_ATTRIBUTE)) continue
      const pages = contentCatalog.findBy({
        component: component.name,
        family: 'page',
        version: componentVersion.version,
      })
      const modules = new Map()
      for (const page of pages) {
        if (page.src.module === 'ROOT') continue
        const modulePages = modules.get(page.src.module) || []
        modulePages.push(page)
        modules.set(page.src.module, modulePages)
      }
      for (const modulePages of modules.values()) {
        enhanced += enhanceModule(modulePages, contentCatalog)
      }
    }
  }
  return enhanced
}

function register () {
  const logger = this.getLogger('bible-navigation')
  this.on('contentClassified', ({ contentCatalog }) => {
    const enhanced = enhanceBibleNavigation(contentCatalog)
    if (enhanced) logger.info(`Added Bible navigation to ${enhanced} pages`)
  })
}

module.exports = {
  enhanceBibleNavigation,
  register,
}
