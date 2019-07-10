{EventEmitter} = require('events')
fs = require 'fs'
VoicePacket = require './voicePacket.coffee'
childProc = require 'child_process'
chunker = require 'stream-chunker'

class AudioPlayer extends EventEmitter
  
  ###
  # PRIVATE METHODS
  ###
  
  constructor: (stream, @voiceConnection, @discordClient) ->
    super()
    @discordClient.Logger.debug("New AudioPlayer constructed")
    @glob_stream = stream
    #setup stream
    @ffmpegDone = false
    @streamFinished = false
    @streamBuffErrorCount = 0
    @seekCnt = 0
    @seekPosition = 0
    @packageList = []
    @waveform = []
    @waveform_packet_size = 1920 * 2 * 20
    self = @
    self.enc = childProc.spawn('ffmpeg', [
      '-i', 'pipe:0',
      '-f', 's16le',
      '-ar', '48000',
      '-ss', '0',
      '-ac', '2',
      '-af', 'bass=g=2:f=140:w=0.7',
      '-vn',
      '-copy_unknown',
      '-loglevel', 'verbose',
      'pipe:1'
    ], {detached: true}).on('error', (e) ->
      self.discordClient.Logger.debug("FFMPEG encoding error: "+e.toString(),"error")
    )
    chnkr = chunker(1920*2, {
      flush: true,
      align: true
    })
    self.opusEncoder = self.voiceConnection.opusEncoder
    temp_waveform = []
    chnkr.on("data", (chunk) ->
      packet = chunk
      i = 0
      while i < packet.length
        if i >= packet.length - 1
          break
        uint = Math.floor(packet.readInt16LE(i))
        uint = Math.min(32767, uint)
        uint = Math.max(-32767, uint)
        # Write 2 new bytes into other buffer;
        temp_waveform.push(uint)
        if temp_waveform.length > self.waveform_packet_size # bucket waveform data, we don't need it to be completely accurate
          maxInt = self.getAverage(temp_waveform)
          temp_waveform = []
          self.waveform.push(maxInt)
        i += 2
      self.waveform = self.normaliseWave(self.waveform, self.getMin(self.waveform), self.getMax(self.waveform), 0, 1)
      self.packageData(chunk)
    )
    stream.pipe(self.enc.stdin)
    self.enc.stdout.pipe(chnkr)

    self.enc.on('error', (err) ->
      self.discordClient.Logger.debug("Error Occurred: "+err.toString(),"error")
    )

    self.enc.stdout.on('error', (err) ->
      self.discordClient.Logger.debug("Error Occurred: "+err.toString(),"error")
    )

    self.enc.stdout.once('end', () ->
      self.discordClient.Logger.debug("Stdout END")
      self.enc.kill()
      process.kill(-self.enc.pid); #stop possible memory leak
    )

    self.enc.once('close', (code, signal) ->
      self.discordClient.Logger.debug "FFMPEG Stream Closed"
      self.enc.stdout.emit("end")
      self.ffmpegDone = true
    )

    self.enc.stderr.once('data', (d) ->
      self.discordClient.Logger.debug("Storing Voice Packets")
      self.stopSend = false
      self.emit("ready")
    )

    self.enc.stderr.on('data', (d) ->
      self.discordClient.Logger.debug("[STDERR]: "+d)
      if d.toString().match(/time=(.*?)\s/gmi)
        regexMatch = /time=(.*?)\s/gmi
        matches = regexMatch.exec(d.toString())
        time = matches[1]
        a = time.split(':')
        seconds = (+a[0]) * 60 * 60 + (+a[1]) * 60 + (+a[2].split(".")[0])
        self.emit("progress", seconds)
        self.emit("VoiceWaveForm", self.waveform, seconds)
    )

    self.enc.stdout.once('readable', () ->
      self.discordClient.Logger.debug("ffmpeg stream readable")
    )

    stream.on('close', () ->
      self.discordClient.Logger.debug("User Stream Closed","warn")
    )

    stream.on('error', (err) ->
      self.discordClient.Logger.debug("User Stream Error","error")
      console.log err
    )

    stream.on('end', () ->
      self.discordClient.Logger.debug "User Stream Ended"
    )

  normaliseWave: (arr, arrMin, arrMax, min, max) ->
    len = arr.length

    while len--
      arr[len] = min + (arr[len]  - arrMin) * (max - min) / (arrMax - arrMin);
    return arr

  getMax: (arr) ->
    len = arr.length;
    max = -Infinity;

    while len--
      max = if arr[len] > max then arr[len] else max

    return max;

  getMin: (arr) ->
    len = arr.length;
    min = Infinity;

    while len--
      min = if arr[len] < min then arr[len] else min

    return min;

  getAverage: (arr) ->
    len = arr.length;
    tot = 0;

    while len--
      tot += arr[len]
    return tot/len;

  packageData: (chunk) ->
    if chunk && chunk instanceof Buffer
      @packageList.push(chunk)

  sendToVoiceConnection: (startTime, cnt) ->
    self = @
    if !@stopSend
      @voiceConnection.buffer_size = new Date(self.packageList.length*20).toISOString().substr(11, 8)
      packet = @packageList.shift()
      if packet
        @voiceConnection.streamPacketList.push(packet)
        @emit("streamTime", self.seekCnt*20)
        @seekPosition = self.seekCnt*20
      else if @ffmpegDone && !@streamFinished
        @streamFinished = true
        @sendEmptyBuffer()
        self.discordClient.Logger.debug("Stream Done in sendToVoiceConnection")
        @emit("streamDone")
        @seekPosition = 0
        self.destroy()
      nextTime = startTime + (cnt+1) * 20
      self.seekCnt++
      return setTimeout(() ->
        self.sendToVoiceConnection(startTime, cnt + 1)
      , 20 + (nextTime - new Date().getTime()));
    else
      self.discordClient.Logger.debug("Stream Paused via stopSend")
      @sendEmptyBuffer()
      @emit("paused")

  sendEmptyBuffer: () ->
    streamBuff = new Buffer(1920*2).fill(0)
    if @packageList
      @voiceConnection.streamPacketList.push(streamBuff)
    else
      @discordClient.Logger.debug("Couldn't send empty buffer","error")

  stopSending: () ->
    @stopSend = true

  ###
  # PUBLIC METHODS
  ###
  
  pause: () ->
    self = @
    self.discordClient.Logger.debug("Pausing Stream")
    @voiceConnection.setSpeaking(false)
    @stopSending()

  play: () ->
    #start sending voice data and turn speaking on for bot
    self = @
    self.discordClient.Logger.debug("Playing Stream")
    self.stopSend = false
    self.voiceConnection.setSpeaking(true)
    @sendEmptyBuffer()
    #self.packageData(@enc.stdout, new Date().getTime(), 1)
    self.sendToVoiceConnection(new Date().getTime(), 1)

  stop: () ->
    #stop sending voice data and turn speaking off for bot
    self = @
    self.discordClient.Logger.debug("Stopping Stream")
    @voiceConnection.streamPacketList = [] #empty current packet list to be sent to avoid stuttering
    @sendEmptyBuffer()
    @voiceConnection.setSpeaking(false)
    self.stopSending()
    try
      self.glob_stream.unpipe()
      self.enc.kill("SIGSTOP")
      self.enc.kill()
      process.kill(-self.enc.pid); #stop possible memory leak
      self.emit("streamDone")
      self.destroy()
    catch err
      self.emit("streamDone")
      self.destroy()
      self.discordClient.Logger.debug("Error stopping sending of voice packets: "+err.toString(),"error")

  stop_kill: () ->
    self = @
    self.discordClient.Logger.debug("Stopping Stream")
    @voiceConnection.streamPacketList = [] #empty current packet list to be sent to avoid stuttering
    @sendEmptyBuffer()
    @voiceConnection.setSpeaking(false)
    self.stopSending()
    try
      self.glob_stream.unpipe()
      self.enc.kill("SIGSTOP")
      self.enc.kill()
      process.kill(-self.enc.pid); #stop possible memory leak
      self.destroy()
    catch err
      self.destroy()
      self.discordClient.Logger.debug("Error stopping sending of voice packets: "+err.toString(),"error")

  destroy: () ->
    delete @

  setVolume: (volume) ->
    @voiceConnection.volume = volume
    multiplier =  Math.pow(volume, 1.660964);
    console.log "Init Volume Multiplier: "+multiplier

  getVolume: () ->
    return @voiceConnection.volume

module.exports = AudioPlayer