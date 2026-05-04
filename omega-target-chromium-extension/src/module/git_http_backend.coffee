# Buffer is not available in browser service worker context,
# but isomorphic-git's UMD bundle references it
globalThis.Buffer = globalThis.Buffer or require('buffer').Buffer

git = require('isomorphic-git')
gitHttp = require('isomorphic-git/http/web')

mainLetters = ['Z','e', 'r', 'o', 'O', 'm','e', 'g', 'a']
optionFilename = mainLetters.concat(['.json']).join('')

createMemFS = ->
  store = {}

  normalize = (p) ->
    parts = p.split('/').filter((x) -> x and x != '.')
    res = []
    for part in parts
      if part == '..'
        res.pop()
      else
        res.push(part)
    return '/' + res.join('/')

  readFile = (path, options, callback) ->
    if typeof options == 'function'
      callback = options
      options = {}
    p = normalize(path)
    data = store[p]
    if data == undefined
      err = new Error("ENOENT: no such file or directory, open '#{path}'")
      err.code = 'ENOENT'
      callback(err)
      return
    if options == 'utf8' or options?.encoding == 'utf8'
      if data instanceof Uint8Array
        data = new TextDecoder().decode(data)
      callback(null, data)
    else
      if typeof data == 'string'
        data = new TextEncoder().encode(data)
      callback(null, data)

  writeFile = (path, data, options, callback) ->
    if typeof options == 'function'
      callback = options
    p = normalize(path)
    if data instanceof Uint8Array
      store[p] = data
    else if typeof data == 'string'
      store[p] = data
    else
      store[p] = new TextEncoder().encode(data)
    callback(null)

  mkdir = (path, options, callback) ->
    if typeof options == 'function'
      callback = options
    callback(null)

  readdir = (path, options, callback) ->
    if typeof options == 'function'
      callback = options
    p = normalize(path)
    p = p + '/' unless p.endsWith('/')
    seen = {}
    files = []
    for key of store
      if key.startsWith(p)
        rest = key.slice(p.length)
        idx = rest.indexOf('/')
        name = if idx >= 0 then rest.slice(0, idx) else rest
        if name and not seen[name]
          seen[name] = true
          files.push(name)
    callback(null, files)

  stat = (path, callback) ->
    p = normalize(path)
    if store[p] != undefined
      data = store[p]
      size = if data?.length? then data.length else 0
      callback(null, {
        isFile: -> true
        isDirectory: -> false
        isSymbolicLink: -> false
        size: size
      })
    else
      hasChildren = false
      prefix = p + '/'
      for key of store
        if key.startsWith(prefix)
          hasChildren = true
          break
      if hasChildren or p == '/'
        callback(null, {
          isFile: -> false
          isDirectory: -> true
          isSymbolicLink: -> false
          size: 0
        })
      else
        err = new Error("ENOENT: no such file or directory, stat '#{path}'")
        err.code = 'ENOENT'
        callback(err)

  lstat = (path, callback) ->
    stat(path, callback)

  unlink = (path, callback) ->
    p = normalize(path)
    delete store[p]
    callback(null)

  rmdir = (path, callback) ->
    p = normalize(path)
    delete store[p]
    prefix = p + '/'
    for key of store
      if key.startsWith(prefix)
        delete store[key]
    callback(null)

  readlink = (path, options, callback) ->
    if typeof options == 'function'
      callback = options
    err = new Error("EINVAL: invalid argument, readlink '#{path}'")
    err.code = 'EINVAL'
    callback(err)

  symlink = (target, path, callback) ->
    p = normalize(path)
    store[p] = target
    callback(null)

  return {
    readFile, writeFile, mkdir, readdir,
    stat, lstat, unlink, rmdir, readlink, symlink
  }

_formatError = (e) ->
  msg = e?.message or e?.toString() or 'Unknown error'
  # Extract HTTP status code if present in the message
  match = msg.match(/\b(\d{3})\b/)
  if match
    return 'HTTP ' + match[1] + ' ' + msg
  msg

class GitHttpBackend
  constructor: (@repoUrl, @token, @username, @branch) ->
    return

  _authHeaders: ->
    # Provide Authorization header directly via btoa (browser-native)
    # instead of relying on isomorphic-git's onAuth flow which uses
    # Buffer internally for base64 encoding
    user = @username or 'git'
    pass = @token or ''
    encoded = btoa(user + ':' + pass)
    return { 'Authorization': 'Basic ' + encoded }

  init: ({withRemoteData}) ->
    fs = createMemFS()
    @fs = fs
    @dir = '/zeroomega-sync'

    console.log('GitHttpBackend: clone start', @repoUrl, 'branch:', @branch)

    return new Promise((resolve, reject) =>
      git.clone({
        fs: fs
        http: gitHttp
        dir: @dir
        url: @repoUrl
        ref: @branch
        singleBranch: true
        depth: 1
        headers: @_authHeaders()
      }).then( =>
        console.log('GitHttpBackend: clone complete')
        git.resolveRef({ fs: fs, dir: @dir, ref: 'HEAD' })
      ).then((oid) =>
        lastCommit = oid
        console.log('GitHttpBackend: HEAD', lastCommit)
        if withRemoteData
          @_readOptions().then((options) ->
            resolve({options, lastGistCommit: lastCommit})
          )
        else
          resolve({lastGistCommit: lastCommit})
      ).catch((e) ->
        console.error('GitHttpBackend: init error', e)
        reject(_formatError(e))
      )
    )

  push: (data) ->
    content = JSON.stringify(data, null, 4)
    fs = @fs
    dir = @dir
    branch = @branch
    headers = @_authHeaders()

    console.log('GitHttpBackend: push start')

    return new Promise((resolve, reject) ->
      fs.writeFile(dir + '/' + optionFilename, content, (err) ->
        if err then reject(err) else resolve()
      )
    ).then( ->
      console.log('GitHttpBackend: add')
      git.add({ fs: fs, dir: dir, filepath: optionFilename })
    ).then( ->
      console.log('GitHttpBackend: commit')
      git.commit({
        fs: fs
        dir: dir
        message: 'ZeroOmega sync'
        author: {
          name: 'ZeroOmega'
          email: 'zero@omega.local'
        }
      })
    ).then((oid) ->
      console.log('GitHttpBackend: push commit', oid)
      git.push({
        fs: fs
        http: gitHttp
        dir: dir
        remote: 'origin'
        ref: branch
        force: true
        headers: headers
      })
    ).then((result) ->
      console.log('GitHttpBackend: push done', result)
      git.resolveRef({ fs: fs, dir: dir, ref: 'HEAD' })
    ).then((oid) ->
      { lastGistCommit: oid }
    ).catch((e) ->
      console.error('GitHttpBackend: push error', e)
      throw _formatError(e)
    )

  pull: ->
    fs = @fs
    dir = @dir
    branch = @branch
    headers = @_authHeaders()

    console.log('GitHttpBackend: pull start')

    return new Promise((resolve, reject) =>
      git.fetch({
        fs: fs
        http: gitHttp
        dir: dir
        url: @repoUrl
        ref: branch
        singleBranch: true
        depth: 1
        headers: headers
      }).then( ->
        console.log('GitHttpBackend: fetch done')
        git.resolveRef({ fs: fs, dir: dir, ref: 'HEAD' })
      ).then((oid) =>
        lastCommit = oid
        console.log('GitHttpBackend: HEAD', lastCommit)
        @_readOptions().then((options) ->
          resolve({options, lastGistCommit: lastCommit})
        )
      ).catch((e) ->
        console.error('GitHttpBackend: pull error', e)
        reject(_formatError(e))
      )
    )

  checkChange: ->
    branch = @branch
    headers = @_authHeaders()

    console.log('GitHttpBackend: checkChange start')

    return git.listServerRefs({
      http: gitHttp
      url: @repoUrl
      prefix: 'refs/heads/' + branch
      headers: headers
    }).then((refs) ->
      console.log('GitHttpBackend: refs', refs)
      remoteRef = refs.find((r) -> r.ref == 'refs/heads/' + branch)
      remoteCommit = remoteRef?.oid
      console.log('GitHttpBackend: remote commit', remoteCommit)
      return remoteCommit
    ).catch((e) ->
      console.error('GitHttpBackend: checkChange error', e)
      throw _formatError(e)
    )

  _readOptions: ->
    return new Promise((resolve, reject) =>
      @fs.readFile(@dir + '/' + optionFilename, 'utf8', (err, data) ->
        if err
          console.log('GitHttpBackend: option file missing', err.message)
          resolve(undefined)
          return
        try
          options = JSON.parse(data)
          console.log('GitHttpBackend: option file parsed')
          resolve(options)
        catch e
          console.error('GitHttpBackend: parse error', e)
          resolve(undefined)
      )
    )

module.exports = GitHttpBackend
