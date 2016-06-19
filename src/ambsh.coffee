###

  A not so elegant way to execute commands on the ambarella shell that runs on the otherwise inaccessible uITRON OS.

  Requires you to have the following code appended to your autoexec.ash:

  while true; do
    d:\commands.ash
    rm d:\commands.ash
    sleep 1
  done

###

async = require 'async'
uuid = require 'node-uuid'

ambsh = (camera, command, callback) ->
  rv = null
  cmdId = uuid.v4()
  timeout = camera.options.cmdTimeout
  pollInterval = 500
  totalWait = 0

  writeCmd = (callback) ->
    cmdStream = camera.createWriteStream '/tmp/fuse_d/commands.ash'
    cmdStream.on 'error', callback
    cmdStream.on 'finish', callback
    cmdStream.write "(#{ command }) > d:\\#{ cmdId }\n"
    cmdStream.end()

  wait = (callback) ->
    file = null
    isReady = -> file?
    check = (callback) ->
      camera.listDirectory '/tmp/fuse_d', (error, result) ->
        unless error?
          file = result.find (f) -> f.name is cmdId
          totalWait += pollInterval
          if not file? and totalWait >= timeout
            error = new Error 'Command timed out, make sure you have the polling loop in your autoexec.ash.'
        callback error
    delayedCheck = (callback) -> setTimeout (-> check callback), pollInterval
    async.until isReady, delayedCheck, callback

  readResult = (callback) ->
    data = []
    resultStream = camera.createReadStream "/tmp/fuse_d/#{ cmdId }"
    resultStream.on 'error', callback
    resultStream.on 'data', (chunk) -> data.push chunk
    resultStream.on 'end', ->
      rv = (Buffer.concat data).toString()
      do callback

  cleanup = (callback) ->
    camera.deleteFile "/tmp/fuse_d/#{ cmdId }", callback

  async.series [writeCmd, wait, readResult, cleanup], (error) -> callback error, rv


module.exports = ambsh
