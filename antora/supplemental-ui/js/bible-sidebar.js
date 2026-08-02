;(function () {
  'use strict'

  var navigation = document.querySelector('.nav-panel-menu')
  if (!navigation) return

  navigation.querySelectorAll('.is-current-page').forEach(function (item) {
    if (!item.querySelector('.nav-list .is-current-page')) return
    item.classList.remove('is-current-page')
    var link = item.querySelector(':scope > .nav-link')
    if (link) link.removeAttribute('aria-current')
  })

  if (navigation.querySelector('.is-current-page')) return

  var currentPath = window.location.pathname
  var closest = null
  var closestDirectoryLength = -1

  navigation.querySelectorAll('.nav-list a.nav-link').forEach(function (link) {
    var target = new URL(link.href, window.location.href)
    if (target.origin !== window.location.origin) return

    var targetPath = target.pathname
    var directory = targetPath.endsWith('/')
      ? targetPath
      : targetPath.slice(0, targetPath.lastIndexOf('/') + 1)

    if (
      directory.length >= closestDirectoryLength &&
      currentPath.startsWith(directory)
    ) {
      closest = link
      closestDirectoryLength = directory.length
    }
  })

  if (!closest) return

  closest.setAttribute('aria-current', 'location')
  var item = closest.closest('.nav-item')
  if (item) item.classList.add('is-current-page-parent')
  while (item && navigation.contains(item)) {
    item.classList.add('is-active', 'is-current-path')
    item = item.parentElement && item.parentElement.closest('.nav-item')
  }
  closest.scrollIntoView({ block: 'nearest' })
})()
