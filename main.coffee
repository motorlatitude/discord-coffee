EventEmitter = require('events').EventEmitter
Constants = require './constants.coffee'
req = require 'request'
pjson = require './package.json'
debug = require('./src/utils/Logger.coffee')
DiscordManager = require './src/rest/DiscordManager'

clientConnection = require './src/client/clientConnection.coffee'

class DiscordClient extends EventEmitter


  constructor: (@options) ->
    super()
    if !@options.token then throw new Error("No Token Provided")
    @Logger = new debug()
    if @options.debug then @Logger.level = @options.debug
    @rest = new DiscordManager(@)

  getGateway: () ->
    self = @
    @Logger.debug("Retrieving Discord Gateway Server")
    req.get({url: Constants.api.host+"/gateway/bot?v=6", json: true, time: true, headers: {
        "Authorization": "Bot "+self.options.token
      }}, (err, res, data) ->
      if res.statusCode != 200 || err
        self.Logger.debug("Error Occurred Obtaining Gateway Server: "+res.statusCode+" "+res.statusMessage,"error")
        return self.emit("disconnect")
      ping = res.elapsedTime
      self.Logger.debug("Gateway Server: "+data.url+" ("+ping+"ms)")
      self.emit("gateway_found", data.url)
      self.establishGatewayConnection(data.url)
    )

  establishGatewayConnection: (gateway) ->
    self = @
    @internals.gateway = gateway
    @internals.token = @options.token
    @connected = false

    cc = new clientConnection(@)
    cc.connect(gateway) #connect to discord gateway server

  #PUBLIC METHODS

  connect: () ->
    @Logger.debug("Starting node-discord "+pjson.version,"info")
    @internals = {}
    @internals.voice = {}
    @internals.sequence = 0
    @channels = {}
    @guilds = {}
    @users = {}
    @voiceHandlers = {}
    @voiceConnections = {}
    @getGateway()

  setDebugLevel: (level) ->
    @Logger.debug("Changing Debug Level To: "+level);
    @options.debug = level;
    @Logger.level = level;

  setStatus: (status, type = 2, state = "online") ->
    since = null
    game = null
    if status != null
      game = {
        "name": status,
        "type": type
      }
    if state == "idle"
      since = new Date().getTime()
    dataMsg = {
      "op": 3,
      "d" :{
        "since": since,
        "game": game,
        "status": state,
        "afk": false
      }
    }
    if @gatewayWS.readyState == @gatewayWS.OPEN
      @gatewayWS.send(JSON.stringify(dataMsg))
      @Logger.debug("Status Successfully Set to \""+status+"\"","info")

  getMembers: (guild_id) ->
    dataMsg = {
      "op": 8,
      "d" :{
        "guild_id": guild_id,
        "query": "",
        "limit": 0
      }
    }
    if @gatewayWS.readyState == @gatewayWS.OPEN
      @gatewayWS.send(JSON.stringify(dataMsg))

  leaveVoiceChannel: (server) ->
    leaveVoicePackage = {
      "op": 4,
      "d": {
        "guild_id": server,
        "channel_id": null,
        "self_mute": false,
        "self_deaf": false
      }
    }
    self = @
    @Logger.debug("Leaving voice channel in guild: "+server,"info")
    self.voiceConnections[server] = {}
    delete self.voiceConnections[server]
    self.gatewayWS.send(JSON.stringify(leaveVoicePackage))

module.exports = DiscordClient
