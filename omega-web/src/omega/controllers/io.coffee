angular.module('omega').controller 'IoCtrl', (
  $scope, $rootScope, $window, $http, omegaTarget, downloadFile
) ->

  $scope.useBuiltInSync = true
  getGistId = (gistUrl = '') ->
    # get gistId from url `https://gist.github.com/{username}/{gistId}`
    # or directly gistId
    gistId = gistUrl.replace(/\/+$/, '')
    gistId = gistId.split('/')
    gistId = gistId[gistId.length - 1]
    return gistId

  isGistUrl = (url = '') ->
    url.indexOf('https://gist.github.com/') == 0

  updateIsGistUrl = ->
    $scope.isGistUrl = isGistUrl($scope.gistId or '')

  $scope.onGistIdChange = ->
    updateIsGistUrl()

  omegaTarget.state([
    'web.restoreOnlineUrl',
    'gistId',
    'gistToken',
    'syncBranch',
    'syncUsername',
    'lastGistSync',
    'lastGistState'
  ]).then ([url, gistId, gistToken, syncBranch,
            syncUsername, lastGistSync, lastGistState]) ->
    if url
      $scope.restoreOnlineUrl = url
    if gistId
      $scope.gistId = gistId
      if isGistUrl(gistId)
        $scope.gistUrl = "https://gist.github.com/" + getGistId(gistId)
    if gistToken
      $scope.gistToken = gistToken
    if syncBranch
      $scope.syncBranch = syncBranch
    if syncUsername
      $scope.syncUsername = syncUsername
    $scope.lastGistSync = new Date(lastGistSync or Date.now())
    $scope.lastGistState = lastGistState or ''
    updateIsGistUrl()

  $scope.exportOptions = ->
    $rootScope.applyOptionsConfirm().then ->
      plainOptions = angular.fromJson(angular.toJson($rootScope.options))
      content = JSON.stringify(plainOptions)
      blob = new Blob [content], {type: "text/plain;charset=utf-8"}
      filename = """ZeroOmegaOptions-#{new Date().toISOString()}.bak"""
      downloadFile(blob, filename)

  $scope.importSuccess = ->
    $rootScope.showAlert(
      type: 'success'
      i18n: 'options_importSuccess'
      message: 'Options imported.'
    )

  $scope.restoreLocal = (content) ->
    $scope.restoringLocal = true
    $rootScope.resetOptions(content).then(( ->
      $scope.importSuccess()
    ), -> $scope.restoreLocalError()).finally ->
      $scope.restoringLocal = false

  $scope.restoreLocalError = ->
    $rootScope.showAlert(
      type: 'error'
      i18n: 'options_importFormatError'
      message: 'Invalid backup file!'
    )
  $scope.downloadError = ->
    $rootScope.showAlert(
      type: 'error'
      i18n: 'options_importDownloadError'
      message: 'Error downloading backup file!'
    )
  $scope.triggerFileInput = ->
    angular.element('#restore-local-file').click()
    return
  $scope.restoreOnline = ->
    omegaTarget.state('web.restoreOnlineUrl', $scope.restoreOnlineUrl)
    $scope.restoringOnline = true
    $http(
      method: 'GET'
      url: $scope.restoreOnlineUrl
      cache: false
      timeout: 10000
      responseType: "text"
    ).then(((result) ->
      $rootScope.resetOptions(result.data).then (->
        $scope.importSuccess()
      ), -> $scope.restoreLocalError()
    ), $scope.downloadError).finally ->
      $scope.restoringOnline = false

  $scope.enableOptionsSync = (args = {}) ->
    enable = ->
      if !$scope.gistId or !$scope.gistToken
        $rootScope.showAlert(
          type: 'error'
          message: 'Gist Id or Gist Token is required'
        )
        return
      if !isGistUrl($scope.gistId) and !$scope.syncBranch
        $rootScope.showAlert(
          type: 'error'
          message: 'Branch is required for Git Remote sync'
        )
        return
      args.gistId = $scope.gistId
      args.gistToken = $scope.gistToken
      args.useBuiltInSync = $scope.useBuiltInSync
      if !isGistUrl($scope.gistId)
        args.syncBranch = $scope.syncBranch
        args.syncUsername = $scope.syncUsername
      $scope.enableOptionsSyncing = true
      omegaTarget.setOptionsSync(true, args).then( ->
        $window.location.reload()
      ).catch((e) ->
        $scope.enableOptionsSyncing = false
        $rootScope.showAlert(
          type: 'error'
          message: e + ''
        )
        console.log('error:::', e)
      )
    if args?.force
      enable()
    else
      $rootScope.applyOptionsConfirm().then enable

  $scope.cleanInput = (target) ->
    $scope[target] = ''
    omegaTarget.state(target, '')

  $scope.checkOptionsSyncChange = ->
    $scope.enableOptionsSyncing = true
    omegaTarget.checkOptionsSyncChange().then( ->
      $window.location.reload()
    )
  $scope.disableOptionsSync = ->
    omegaTarget.setOptionsSync(false).then ->
      $rootScope.applyOptionsConfirm().then ->
        $window.location.reload()

  $scope.resetOptionsSync = ->
    if !$scope.gistId or !$scope.gistToken
      $rootScope.showAlert(
        type: 'error'
        message: 'Gist Id or Gist Token is required'
      )
      return
    resetArgs = {
      gistId: $scope.gistId
      gistToken: $scope.gistToken
    }
    if !isGistUrl($scope.gistId)
      resetArgs.syncBranch = $scope.syncBranch
      resetArgs.syncUsername = $scope.syncUsername
    omegaTarget.resetOptionsSync(resetArgs).then( ->
      $rootScope.applyOptionsConfirm().then ->
        $window.location.reload()
    ).catch((e) ->
      $rootScope.showAlert(
        type: 'error'
        message: e + ''
      )
      console.log('error:::', e)
    )
