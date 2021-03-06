#META { "name": "localFileServer" } *//

class localFileServer
  getName: -> "Local File Server"
  getDescription: -> "Hosts a selected folder so you can use local files in your theme. Has to restart discord first time enabling."
  getAuthor: -> "square"
  getVersion: -> "1.0.2"

  load: ->

  start: ->
    assertMainProcJsPatch()
    getSettings()
    startServer()
    return

  stop: ->
    stopServer()
    return

  fs = require "fs"
  path = require "path"
  https = require "https"
  url = require "url"
  {remote, shell} = require("electron")
  {dialog, app} = remote
  bw = remote.getCurrentWindow()

  settings = server = null

  getSettings = ->
    settings = (bdPluginStorage.get "localFileServer", "settings") ? {}
    settings[k] ?= v for k, v of {
      folder: path.join process.env[if process.platform is "win32" then "USERPROFILE" else "HOME"], "pictures"
      port: 35724
    }
    return

  getSettingsPanel: ->
    getSettings()
    """<div id="settings_localFileServer">
      <style>
      #settings_localFileServer {
        color: #87909C;
      }
      #settings_localFileServer button {
        background: rgba(128,128,128,0.4);
        width: calc(100% - 20px);
        padding: 5px 10px;
        box-sizing: content-box;
        height: 1em;
        font-size: 1em;
        line-height: 0.1em;
      }
      #settings_localFileServer input {
        text-align: center;
        width: 63px;
        border-width: 0;
        outline-width: 0;
      }
      #settings_localFileServer .invalid {
        background: rgba(255,0,0,.5);
        font-weight: 500;
      }
      #settings_localFileServer * {
        margin-bottom: 2px;
      }
      </style>
      <button name="folder" #{if fs.existsSync settings.folder then "" else "class=\"invalid\" "}type="button" onclick="localFileServer.chooseDirectory()">#{settings.folder}</button>
      <button type="button" onclick="localFileServer.openInBrowser()">Open in browser.</button>
      Port: <input name="port" type="number" value="#{settings.port}" placeholder="...port..." oninput="localFileServer.updateSettings()" autocomplete="off" />
      only accepts 443 and [10001-65535]
    </div>"""

  @openInBrowser: ->
    shell.openExternal "https://localhost:#{settings.port}/"
    return

  @chooseDirectory: ->
    dialog.showOpenDialog bw, defaultPath: settings.folder, buttonLabel: "Choose", properties: \
        ["openDirectory", "showHiddenFiles", "createDirectory", "noResolveAliases", "treatPackageAsDirectory"], \
        (selection) =>
      document.querySelector("#settings_localFileServer button").innerHTML = selection?[0] ? ""
      @updateSettings()
    return

  @updateSettings: ->
    oldPort = settings.port
    for input in document.querySelectorAll "#settings_localFileServer :-webkit-any(input, button, checkbox)"
      {name, type, value} = input
      continue unless name
      if type is "button"
        value = input.innerHTML
      else if type is "checkbox"
        value = input.checked
      if (switch name
        when "folder"
          value and path.isAbsolute(value) and fs.existsSync value = path.normalize value
        when "port"
          /^[0-9]+$/.test(value) and (1e4 < (value = 0|value) <= 0xFFFF or 443 is value)
        else true
      )
        settings[name] = value
        input.className = ""
      else
        input.className = "invalid"
        input.innerHTML = "invalid path" if name is "folder"
    bdPluginStorage.set "localFileServer", "settings", settings
    if oldPort isnt settings.port
      stopServer()
      startServer()
    return

  startServer = ->
    remote.getGlobal("localFileServerMainProcObj")?.port = if 443 is settings.port then "" else ":#{settings.port}"
    server = https.createServer {pfx}, onRequest
    server.on "error", (e) ->
      console.error e
      return
    server.timeout = 10e3
    server.keepAliveTimeout = 0
    server.listen settings.port, "127.0.0.1"
    return

  stopServer = ->
    remote.getGlobal("localFileServerMainProcObj")?.port = null
    server.close()
    return

  onRequest = (req, res) ->
    if req.url.endsWith "/favicon.ico"
      res.writeHead 200
      res.end favicon
      return
    _path = path.normalize path.join settings.folder, decodeURIComponent url.parse(req.url).path
    _path = _path[...-1] if _path[_path.length - 1] is path.sep
    fs.lstat _path, (e, stats) ->
      if e?
        res.writeHead 500, e.message
        res.end()
        return console.error e
      if !stats.isDirectory() then fs.readFile _path, (e, buffer) ->
        if e?
          res.writeHead 500, e.message
          res.end()
          return console.error e
        res.writeHead 200
        res.end buffer
        return
      else fs.readdir _path, (e, files) ->
        if e?
          res.writeHead 500, e.message
          res.end()
          return console.error e
        res.writeHead 200, "Content-Type": "text/html"
        res.write """<html><head><title>Local File Server</title><base href="#{if req.url[req.url.length - 1] is "/" then req.url else req.url + "/"}" /><style>
            a { float: left; margin: 5px; display: inline-block; }
            br { clear: left; }
            .image { width: 100%; max-width: 300px; height: 200px; background: #20242a 50%/contain no-repeat; border: solid 1px black; }
          </style></head><body>"""
        files.unshift ".." unless _path is settings.folder
        images = []
        for file in files
          if isImage file
            images.push file
            continue
          res.write """<a href="#{encodeURIComponent file}">#{file}</a>"""
        res.write "<br/>"
        for image in images
          res.write """<a href="#{encoded = encodeURIComponent image}" class="image" style="background-image: url('#{encoded}');" />"""
        res.end "</body></html>"
        return
      return
    return

  assertMainProcJsPatch = ->
    split = "app.setVersion(discordVersion);"
    mainjs =
      """
        \r\n\r\n// localFileServer plugin start     #ref1#
        global.localFileServerMainProcObj={port:null};
        app.commandLine.appendSwitch("allow-insecure-localhost");
        app.on("certificate-error",(ev,x,url,y,z,cb)=>(new RegExp(`https://(localhost|127\\\\.0\\\\.0\\\\.1)${localFileServerMainProcObj.port}/`)).test(url)?(ev.preventDefault(),cb(!0)):cb(!1));
        // localFileServer plugin end\r\n
      """

    _path = path.join app.getAppPath(), "index.js"
    fs.readFile _path, "utf8", (e, data) ->
      return console.error e if e?
      return if -1 isnt data.indexOf mainjs
      newData = data.split(split).join "#{split}#{mainjs}"
      throw "localFileServer needs fixing!" if data.length + mainjs.length isnt newData.length
      fs.writeFile _path, newData, (e) ->
        return console.error e if e?
        app.relaunch()
        app.quit()
        return
      return

    return

  isImage = (filename) -> filename[filename.lastIndexOf(".")...] in [".png",".jpeg", ".jpg", ".bmp", ".gif", ".webp", ".svg", ".tiff", ".apng"]

  favicon = Buffer.from(
    """AAABAAEAEBAQAAEABAAoAQAAFgAAACgAAAAQAAAAIAAAAAEABAAAAAAAgAAAAMMOAADDDgAAEAAAABAAAAAAAAAAL2sUAEyxIgAXNgoA////AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAASIiIiIiEAACEDIAIwEgAAIDIxEyMCAAAjIAAAAjIAACIQEREBIgAAIDAQAQMCAAAgMBABAwIAACIQEREBIgAAIyAAAAIyAAAgMjETIwIAACEDIAIwEgAAEiIiIiIhAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"""
    "base64"
  )

  pfx = Buffer.from(
    """MIIJOgIBAzCCCPYGCSqGSIb3DQEHAaCCCOcEggjjMIII3zCCBggGCSqGSIb3DQEHAaCCBfkEggX1MIIF8TCCBe0GCyqGSIb3DQEMCgECoIIE/jCCBPowHAYKKoZIhvcNAQwBAzAOBAgdXkoB55/j7QICB9AEggTY8LQ/W6ztvehDIIsZZ15J8jsSvsTD5tCwm6tazSYArSk1zavcCgW3a6y/GLoS4ooiRnsMDM3DIqJtzInewJmlbCFx9jpPuubci/p63Lq3G5ltc9dLHIwBSYKk9GxiwDqzUK4Pp4Gc1xtMFcQB77zckCRVIAjyxG9uVVywjDCG5qikIsMGgDMw4SQz6mADQf+D/LFB5N6piHaTTq4borZVmouClGW7WkkVnenVX3wp+/3DCZlcLKkXaNJRQK0cJyVvMRsdvJpNII2Tz/usOsBBEZZRYpkr0GP/jWVLfL2jxrstTAl6in2kEFlHAaJi8yz7DmjoiVmXvFJLdAh5IzRcRZk4VdLjGbhsSPFdvmPNlCaCaX3jPr2PvESda8eDGqpF5Y+tnOa75fkplhiDUpwsg+EJR0HoTB78G+G2imqzINaI6fst+mDIRIyRHxyyXg2LR0QVfcq0E4YyIfz9PIvQl7+3Mwk0FMjXFVd62E8Hz53kQmYfi44E7Mpxz2HgzHqHZ0wqlzHa8ENivXKvspmzUGFRsXDHqxp9cM7TCzFtGOZDzQnk5yDQV9CZ0Vq7CGHoEW+voHxHYoyyCImkSziMNfyq8uDrsFnus9O4sVp1p7nqWHeT7bklb87kCecLxjmRBfG12XycdrfI6897EMpks1d9uVc3DkiUa3CC/3g9Ox+hE97rs9JDgExDaa/oD5aYDSMyQQnJPf4BFMFHk+EMjFtuCEGa16HfsCrYad2TW9/lVntHL56QsMhXvz9JcZZWugV08j0BtY/ufN/jesBdOHYS1Z4dYBu8rY3eQjNzgKzkimOJvYJhMhMtlXKuffTAcX/9H5xZtyLV9OuKXtLbnvX4XAuL1PeWn1OlWwesQ/RtIOn+ufE4eFnx0EuNnQGGEYkA1qw6R16NVaKY/qQZtkvfij4dy+CFbTuLgVk945/tdUSF5BTaXYYI/ngEqiXgOcPtNktR0JIEzY+hL3NNxlq5x4ecR2iOLzafQL7w2Ze9WIuPa37R0r/6Sw1KvZHV9VxkFqiDD1JhLs5DNldW6VIode9M1mFAovf2Mxfq7fsmmEi/JJX6nNnxse7L0yN6JM80BVVIbRMqpdVc3L0OoeyaXdVMpoRoiOwH2NC28ACW0GOq+rsprjnzHk3eKFNa2+gM8Iv4DWZ6s6pMy2Ak6TgYngpPMo8/Q27dy8zptf6wF84fl8mklLsSTaZrkM7Opudft94bD9Fj45yEFCg95woEOUoCCFUIRhgQQA1voVGB8WqKp2s4QEWqPlHHvDrp56UOALc6a5ElL5rs3zCzTqlLk0DJRgVVzh1YwzD9y6etaf0PqdKBn94B4k5DIDOF1zi8txxA4q1w93NGT+A+Xz4tUoZEOYvQ5Qs4o3aO++xQL1zyFy+8UCDcDkvrGg+oE1iCmYWyb6h63YN5UXtx3IYyioYsB0zkCOPwe5CQl9ly3qdMXafc3uegL2S76V1NdnTDGQAIk5HqA4TcEK27W7r6yu7jqdZjXvDzTvQ8KEi+A5PZqqs4Xd/jEoCNcjArNrG0+55Anlr1AJas1vMUvU2X+cszPjetQz+qhdiErGc+zVKXKRVRy2l6LECS295PQFjLFVEIMynljeVhQSv3JeMyqdaT91dWGzIQPzEIryFnamiNMKfZJjGB2zATBgkqhkiG9w0BCRUxBgQEAQAAADBdBgkrBgEEAYI3EQExUB5OAE0AaQBjAHIAbwBzAG8AZgB0ACAAUwB0AHIAbwBuAGcAIABDAHIAeQBwAHQAbwBnAHIAYQBwAGgAaQBjACAAUAByAG8AdgBpAGQAZQByMGUGCSqGSIb3DQEJFDFYHlYAUAB2AGsAVABtAHAAOgBjADkANQAwAGIAMgAzADQALQA2AGEAMwBiAC0ANABmADAAMwAtAGIAMwA4ADEALQA1ADgAOQBmADcAMwAwADkAYgBlAGMANzCCAs8GCSqGSIb3DQEHBqCCAsAwggK8AgEAMIICtQYJKoZIhvcNAQcBMBwGCiqGSIb3DQEMAQYwDgQIiFu0Avj47x4CAgfQgIICiICeBLv6Mh6eAxRHENt6aPiHRowNmr9fH0R7sBfXHYXbIctMZVVbM28QPgANqkE+YEdh8tNpP8wVG7qASvV/TsLTTKhqTJXO8B2iprDF6KY68wILX3OU8iW3jYXisoSRNyihtDF0wc12vHqH4BKLoK5g02XYuuos/zuvYnQ0kVaXIZ6MiZZHFH0MY4j1inTLKWDamB8YGq/mHpQvX5IORoMaDwbEBfXQ21GMy3pWuMjUGO4meK9KO0P8s35UA8yvXrycSS1zs6TSSOaxZY3LLo096VVbidybHk5sM/e8cjVzTiaHXXwPV0z56+0v+Uv8fpErfUSO8RHyjIwRJDUo8q8li9EkS25N/zU1uHUuhwcpu65bGEP/iMrY+yFfX1uvzCju0swfFPayMWH1B+sDUJ3XbBZooPKGaxGVQWGbETXUd2UtHUlafU0GYDn2h7DRt8yD0rnz9QzCKQnloVdf2VNQS2szVhhGkhZ/Sbd8AEawxZ0CaZdPWS0hmh9BywbGJEvJ6YCGQtCS9zoNQwZX3Li6QZ1KVcmjoNTsvtZwiI4kWdkkamSbdqy7tggKEvU/m5++W1Q7j8Wr2FvxOGPJuQ6NmI/mow3xTRor02h/biFV39SW+xOcSI43/3HT3XZVo5THm/5OC6jtZE3MuZiA1nhT0z3f112UAFO2+H/pqtOY2qWSJPYSCY6E9w5vYT8+lnFaHTqDVWwY/uRHNCLcasGn8saBa7YL6dgtjxVxqlP1s7V+2tWWElZUfc1TnzZmTrQEAMPTXpRcK4XAUO3BuB/AE2tzIAffvAyKIvJ/tG3WQYghF4XnRHRY25FL5lfTxbl7adfGFJiLPq3sw5Ej4psVCwMYFTguZzA7MB8wBwYFKw4DAhoEFO7uLowGFBo8A/KkXH7nItFXsVk0BBRfsf8Tnl1A1JoztFXEvXViGFvH9AICB9A="""
    "base64"
  )

global.localFileServer = localFileServer
