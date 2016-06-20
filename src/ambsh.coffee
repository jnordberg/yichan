###

  A not so elegant way to execute commands on the ambarella shell that runs on the otherwise inaccessible uITRON OS.

  Requires you to have the following code appended to your autoexec.ash:

  while true; do
    if mv d:\commands.lock d:\commands.locked; then
      d:\commands.ash
      rm d:\commands.ash
      rm d:\commands.locked
    fi
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

  scriptFile = "#{ cmdId }.ash"
  responseFile = "#{ cmdId }.txt"

  writeScript = (callback) ->
    script = camera.createWriteStream "/tmp/fuse_d/#{ scriptFile }"
    script.on 'error', callback
    script.on 'finish', callback
    script.write command + '\n'
    setImmediate -> do script.end

  writeCommands = (callback) ->
    commands = camera.createWriteStream '/tmp/fuse_d/commands.ash'
    commands.on 'error', callback
    commands.on 'finish', callback
    cmd = """
      d:\\#{ scriptFile } > d:\\#{ responseFile }
      rm d:\\commands.ash
    """
    commands.write cmd + '\n'
    setImmediate -> do commands.end

  writeLock = (callback) ->
    file = camera.createWriteStream '/tmp/fuse_d/commands.lock'
    file.on 'error', callback
    file.on 'finish', callback
    file.write cmdId + '\n'
    setImmediate -> do file.end

  lastList = null
  wait = (callback) ->
    file = null
    isReady = -> file?
    check = (callback) ->
      camera.listDirectory '/tmp/fuse_d', (error, result) ->
        unless error?
          lastList = result
          file = result.find (f) -> f.name is responseFile
          totalWait += pollInterval
          if not file? and totalWait >= timeout
            error = new Error 'Command timed out, make sure you have the polling loop in your autoexec.ash.'
        callback error
    delayedCheck = (callback) -> setTimeout (-> check callback), pollInterval
    async.until isReady, delayedCheck, callback

  readResult = (callback) ->
    data = []
    resultStream = camera.createReadStream "/tmp/fuse_d/#{ responseFile }"
    resultStream.on 'error', callback
    resultStream.on 'data', (chunk) -> data.push chunk
    resultStream.on 'end', ->
      rv = (Buffer.concat data).toString()
      do callback

  cleanup = (callback) ->
    deleteFile = (file, callback) -> camera.deleteFile "/tmp/fuse_d/#{ file }", callback
    async.mapSeries [scriptFile, responseFile], deleteFile, callback

  async.series [writeScript, writeCommands, writeLock, wait, readResult, cleanup], (error) ->
    if error? and lastList? and (lastList.find (f) -> f.name is 'commands.ash')?
      process.stderr.write 'WARNING: command not executed properly, removing commands.ash\n'
      camera.deleteFile '/tmp/fuse_d/commands.ash', (deleteErr) -> callback error
    else
      callback error, rv


module.exports = ambsh
