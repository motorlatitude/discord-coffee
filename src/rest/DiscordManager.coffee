DiscordMethods = require './DiscordMethods'
Requester = require './Requester'

class DiscordManager

  constructor: (@client) ->
    @requester = new Requester(@client.options.token)

  methods: () ->
    return new DiscordMethods(@client, @requester)

module.exports = DiscordManager