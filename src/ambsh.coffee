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

ambsh = (camera, command, callback) ->
  rv = null
  timeout = camera.options.cmdTimeout
  pollInterval = 500
  totalWait = 0

  removeOld = (callback) ->
    camera.listDirectory '/tmp/fuse_d/commands', (error, result) ->
      if not error? and (result.find (file) -> file.name is 'yichan.ash')?
        camera.deleteFile '/tmp/fuse_d/commands/yichan.ash', callback
      else
        callback error

  writeScript = (callback) ->
    file = camera.createWriteStream '/tmp/fuse_d/commands/yichan.ash'
    file.on 'error', callback
    file.on 'finish', callback
    file.write command + '\n'
    setImmediate -> do file.end

  writeCommands = (callback) ->
    file = camera.createWriteStream '/tmp/fuse_d/commands/exec.ash'
    file.on 'error', callback
    file.on 'finish', callback
    cmd = """
      d:\\commands\\yichan.ash > d:\\commands\\yichan.txt
      rm d:\\commands\\yichan.ash
    """
    file.write cmd + '\n'
    setImmediate -> do file.end

  writeLock = (callback) ->
    file = camera.createWriteStream '/tmp/fuse_d/commands/lock'
    file.on 'error', callback
    file.on 'finish', callback
    file.write 'yichan\n'
    setImmediate -> do file.end

  wait = (callback) ->
    files = []
    isReady = -> ('yichan.txt' in files) and ('yichan.ash' not in files)
    check = (callback) ->
      camera.listDirectory '/tmp/fuse_d/commands', (error, result) ->
        unless error?
          files = result.map (file) -> file.name
          totalWait += pollInterval
          if not file? and totalWait >= timeout
            error = new Error 'Command timed out, make sure you have the polling loop in your autoexec.ash.'
        callback error
    delayedCheck = (callback) -> setTimeout (-> check callback), pollInterval
    async.until isReady, delayedCheck, callback

  readResult = (callback) ->
    data = []
    resultStream = camera.createReadStream '/tmp/fuse_d/commands/yichan.txt'
    resultStream.on 'error', callback
    resultStream.on 'data', (chunk) -> data.push chunk
    resultStream.on 'end', ->
      rv = (Buffer.concat data).toString()
      do callback

  async.series [removeOld, writeScript, writeCommands, writeLock, wait, readResult], (error) ->
    callback error, rv


module.exports = ambsh
