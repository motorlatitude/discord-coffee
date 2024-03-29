ws = require 'ws'
zlib = require 'zlib'
os = require 'os'
d = require './dispatcher.coffee'

class ClientConnection
  HEARTBEAT_INTERVAL: null
  constructor: (@discordClient) ->
    @gatewayHeartbeat = null
    @discordClient.gatewayWS = null
    @dispatcher = new d(@discordClient, @)
    @discordClient.internals.pings = []
    @discordClient.internals.totalPings = 0
    @discordClient.internals.avgPing = 0
    @discordClient.internals.resuming = false
    @discordClient.internals.connection_retry_count = 0

  connect: (@gateway) ->
    self = @
    @discordClient.internals.gateway = @gateway
    @discordClient.Logger.debug("[GATEWAYSOCKET]: Creating Gateway Connection")
    @discordClient.gatewayWS = new ws(self.gateway+"/?v=6") #use version 6, cause you can do that :o

    @discordClient.gatewayWS.once('open', () -> self.gatewayOpen())
    @discordClient.gatewayWS.once('close', () -> self.gatewayClose())
    @discordClient.gatewayWS.once('error', (err) -> self.gatewayError(err))
    @discordClient.gatewayWS.on('message', (msg) -> self.gatewayMessage(msg))
    #@discordClient.emit("con")

  gatewayError: (err) ->
    @discordClient.Logger.debug("[GATEWAYSOCKET]: Error Occurred Connecting to Gateway Server: "+err.toString(),"error")

  gatewayClose: () ->
    @discordClient.Logger.debug("[GATEWAYSOCKET]: Connection to Gateway Server CLOSED","warn")
    @discordClient.Logger.debug("[GATEWAYSOCKET]: Attempting To Reacquire Connection to Gateway Server","info")
    clearInterval(@gatewayHeartbeat)
    @sendResumePayload()

  gatewayOpen: () ->
    @discordClient.Logger.debug("Connected to Gateway Server","info")
    if @discordClient.internals.resuming
      resumePackage = {
        "op": 6,
        "d": {
          "token": @discordClient.internals.token,
          "session_id": @discordClient.internals.session_id,
          "seq": @discordClient.internals.sequence
        }
      }
      @discordClient.Logger.debug("Sending Resume Package")
      console.log resumePackage
      @discordClient.gatewayWS.send(JSON.stringify(resumePackage))
      @discordClient.Logger.debug("[GATEWAYSOCKET] ~> ["+@gateway.toUpperCase()+"]: Sent RESUME Payload")

  sendResumePayload: () ->
    if @discordClient.internals.connection_retry_count < 5
      @discordClient.internals.resuming = true
      @discordClient.connected = false
      @discordClient.internals.connection_retry_count++
      self = @
      setTimeout(() ->
        self.connect(self.gateway)
      , 1000)
    else
      @discordClient.Logger.debug("[GATEWAYSOCKET]: Failed to Resume Connection: Retry Limit Exceeded","error")
      @discordClient.Logger.debug("[GATEWAYSOCKET]: Terminating","warn")

  sendReadyPayload: () ->
    @discordClient.Logger.debug("[GATEWAYSOCKET]: Using Compression: "+!!zlib.inflateSync)
    idpackage = {
      "op": 2,
      "d": {
        "token": @discordClient.internals.token,
        "properties": {
          "$os": os.platform(),
          "$browser": "discordClient",
          "$device": "discordClient",
          "$referrer": "",
          "$referring_domain": ""
        },
        "compress": !!zlib.inflateSync,
        "large_threshold": 250
      }
    }
    @discordClient.gatewayWS.send(JSON.stringify(idpackage))
    @discordClient.Logger.debug("[GATEWAYSOCKET] ~> ["+@gateway.toUpperCase()+"]: Sent IDENTITY Payload")

  helloPackage: (data) ->
    @discordClient.Logger.debug("[GATEWAYSOCKET] <~ ["+@gateway.toUpperCase()+"]: HELLO Payload Received")
    if @discordClient.internals.resuming
      @discordClient.Logger.debug("[GATEWAYSOCKET]: Ignoring Hello, attempting resume")
      @HEARTBEAT_INTERVAL = data.d.heartbeat_interval
    else
      @HEARTBEAT_INTERVAL = data.d.heartbeat_interval
      @sendReadyPayload()
    self = @
    # Setup gateway heartbeat
    @discordClient.Logger.debug("[GATEWAYSOCKET]: Starting Heartbeat: "+@HEARTBEAT_INTERVAL)
    self.discordClient.internals.gatewayStart = new Date().getTime()
    @gatewayHeartbeat = setInterval(() ->
      hbPackage = {
        "op": 1
        "d": self.discordClient.internals.sequence
      }
      self.discordClient.internals.gatewayPing = new Date().getTime()
      if self.discordClient.gatewayWS
        self.discordClient.gatewayWS.send(JSON.stringify(hbPackage))
        self.discordClient.Logger.debug("[GATEWAYSOCKET] ~> ["+self.gateway.toUpperCase()+"]: Sent Heartbeat")
      else
        self.discordClient.Logger.debug("[GATEWAYSOCKET]: Gateway WebSocket Closed?","error")
    ,@HEARTBEAT_INTERVAL)

  heartbeatACK: (data) ->
    ping = new Date().getTime() - @discordClient.internals.gatewayPing
    @discordClient.internals.pings.push(ping)
    @discordClient.internals.totalPings+=ping
    @discordClient.internals.avgPing = @discordClient.internals.totalPings/@discordClient.internals.pings.length
    @discordClient.Logger.debug("[GATEWAYSOCKET] <~ ["+@gateway.toUpperCase()+"]: Heartbeat acknowledged with sequence: "+@discordClient.internals.sequence+" ("+ping+"ms - average: "+((Math.round(@discordClient.internals.avgPing*100))/100)+"ms)")

  handleInvalidSession: (data) ->
    self = @
    if @discordClient.internals.resuming
      @discordClient.Logger.debug("[GATEWAYSOCKET]: Resuming Failed: INVALID_SESSION","error")
      @discordClient.Logger.debug("[GATEWAYSOCKET]: Attempting Full Reconnect")
      clearInterval(@gatewayHeartbeat)
      @discordClient.internals.resuming = false
      @connect(self.gateway)

  gatewayMessage: (data) ->
    if typeof data != "string"
      msg = if typeof data != "string" then JSON.parse(zlib.inflateSync(data).toString()) else JSON.parse(data)
    else
      if typeof data == "object"
        @discordClient.Logger.debug("[GATEWAYSOCKET]: Received Gateway Message With Type Object -> Buffer","warn")
        msg = {op: -1}
      else
        msg = JSON.parse(data)
    HELLO = 10
    HEARTBEAT_ACK = 11
    DISPATCH = 0
    INVALID_SESSION = 9
    switch msg.op
      when HELLO then @helloPackage(msg)
      when HEARTBEAT_ACK then @heartbeatACK(msg)
      when DISPATCH then @dispatcher.parseDispatch(msg)
      when INVALID_SESSION then @handleInvalidSession(msg)
      else
        @discordClient.Logger.debug("Unhandled op: "+msg.op, "warn")

module.exports = ClientConnection
