Constants = require './../constants.coffee'
req = require 'request'

class Requester

  constructor: (@token) ->
    @host = Constants.api.host

  sendRequest: (method, endpoint, data) ->
    self = @
    return new Promise((resolve, reject) ->
      req({
        url: self.host+endpoint,
        method: method
        headers: {
          "Authorization": "Bot "+self.token
        },
        json: true
        body: data
      }, (err, httpResponse, body) ->
          #console.log body
          if httpResponse
            status = httpResponse.statusCode
            #utils.debug(status+" "+httpResponse.statusMessage+" => "+method+" - "+endpoint)
            if err
              reject(err)
            else if status == 400 || status == 401 || status == 403 || status == 404 || status == 405 || status == 429 || status == 502 || status == 500
              reject({statusCode: status, statusMessage: httpResponse.statusMessage, body: body})
            else
              resolve({httpResponse: httpResponse, body: body})
          else
            reject({statusCode: 500, statusMessage: "No Response", body: body})
        )
    )

  sendUploadRequest: (method, endpoint, data, file, filename) ->
    self = @
    return new Promise((resolve, reject) ->
      r = req({
        url: self.host+endpoint,
        method: method
        headers: {
          "Authorization": "Bot "+self.token,
          "Content-Type": "multipart/form-data"
        }
      }, (err, httpResponse, body) ->
        #console.log body
        status = httpResponse.statusCode
        #utils.debug(status+" "+httpResponse.statusMessage+" => "+method+" - "+endpoint)
        if err
          reject(err)
        else if status == 400 || status == 401 || status == 403 || status == 404 || status == 405 || status == 429 || status == 502 || status == 500
          reject({statusCode: status, statusMessage: httpResponse.statusMessage, body: body})
        else
          resolve({httpResponse: httpResponse, body: body})
      )
      form = r.form();
      form.append('file', file, {filename: filename})
      if data.content then form.append('content', data.content)
      if data.tts then form.append('tts', data.tts)
      if data.nonce then form.append('nonce', data.nonce)
    )

module.exports = Requester