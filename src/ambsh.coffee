###

  A not so elegant way to execute commands on the ambarella shell that runs on the otherwise inaccessible uITRON OS.

  Requires you to have the following code appended to your autoexec.ash:

  mkdir d:\commands
  while true; do
    if (mv d:\commands\lock d:\commands\locked) > d:\.null; then
      rm d:\commands\locked > d:\.null
      d:\commands\exec.ash > d:\.null
      rm d:\commands\exec.ash > d:\.null
    fi
    sleep 1
  done

###

async = require 'async'
uuid = require 'node-uuid'

ambsh = (camera, command, callback) ->
  rv = null
  timeout = camera.options.cmdTimeout
  pollInterval = 500
  totalWait = 0

  cmdId = uuid.v4().replace /-/g, ''
  scriptFile = "yichan_#{ cmdId }.ash"
  responseFile = "yichan_#{ cmdId }.txt"

  removeOld = (callback) ->
    deleteFile = (file, callback) ->
      camera.deleteFile "/tmp/fuse_d/commands/#{ file.name }", callback
    camera.listDirectory '/tmp/fuse_d/commands', (error, result) ->
      unless error?
        files = result.filter (file) -> file.name.match /^yichan/
        async.forEachSeries files, deleteFile, callback
      else
        callback error

  writeCommands = (callback) ->
    file = camera.createWriteStream "/tmp/fuse_d/commands/#{ scriptFile }"
    file.on 'error', callback
    file.on 'finish', callback
    file.write command + '\n'
    setImmediate -> do file.end

  writeExec = (callback) ->
    file = camera.createWriteStream '/tmp/fuse_d/commands/exec.ash'
    file.on 'error', callback
    file.on 'finish', callback
    cmd = """
      d:\\commands\\#{ scriptFile } > d:\\commands\\#{ responseFile }
    """
    file.write cmd + '\n'
    setImmediate -> do file.end

  writeLock = (callback) ->
    file = camera.createWriteStream '/tmp/fuse_d/commands/lock'
    file.on 'error', callback
    file.on 'finish', callback
    file.write "yichan_#{ cmdId }"
    setImmediate -> do file.end

  wait = (callback) ->
    files = []
    isReady = -> (responseFile in files)
    check = (callback) ->
      camera.listDirectory '/tmp/fuse_d/commands', (error, result) ->
        unless error?
          files = result.map (file) -> file.name
          totalWait += pollInterval
          if totalWait >= timeout and not isReady()
            error = new Error 'Command timed out, make sure you have the polling loop in your autoexec.ash.'
        callback error
    delayedCheck = (callback) -> setTimeout (-> check callback), pollInterval
    async.until isReady, delayedCheck, callback

  readResult = (callback) ->
    data = []
    resultStream = camera.createReadStream "/tmp/fuse_d/commands/#{ responseFile }"
    resultStream.on 'error', callback
    resultStream.on 'data', (chunk) -> data.push chunk
    resultStream.on 'end', ->
      rv = (Buffer.concat data).toString()
      do callback

  async.series [removeOld, writeCommands, writeExec, writeLock, wait, readResult], (error) ->
    callback error, rv


module.exports = ambsh
