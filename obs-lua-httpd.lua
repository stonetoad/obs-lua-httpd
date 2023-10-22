--[[
A very minimal webserver as an OBS plugin.

Specifically we provide cross-origin isolation headers to
enable SharedArrayBuffer use. This is required for Godot web projects to run.

N.B. that any file with a recognized extension in the directory or any
subdirectory of the webroot will be served

Author: StoneToad

Copyright 2023 StoneToad

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

(from https://opensource.org/license/mit/)

]]--

local obs = obslua
local socket = require("ljsocket")

local debug = false
local bind_host = "127.0.0.1"
local poll_interval = 500 -- millisecond poll interval
local poll_interval_fast = 30
local max_fast_idle = 20
local def_settings = {
	run = false,
	port = 42069,
	debug = false,
}

-- you can load your project via the godot debug web server
-- and check the browser's network debug stuff to see what
-- content type godot's debug server is providing
local content_type_mapping = {
	html = "text/html",
	js = "application/javascript",
	png = "image/png",
	wasm = "application/wasm",
	pck = "application/octet-stream",
}

local description = string.format([[
<h1>Minimal webserver</h1>
For local file browser sources that require security headers.
<br>Primarily intended for Godot web exports:
<br>Set webroot to where you exported the godot project
<br>Point the browser source to: <code>http://127.0.0.1:&lt;port&gt;/&lt;name_of_project&gt;.html</code>
<br>
<br>If you're using the default port, you can just copy-paste this link to test:
<br><a href="http://127.0.0.1:%s/">http://127.0.0.1:%s/</a>
]], def_settings.port, def_settings.port)

-- script global variables
local cur_settings = {}
local sock = nil

function debug_print(str)
	if cur_settings.debug then
		print(str)
	end
end

function script_description()
	return description
end

function script_load(settings)
	print("Loading script " .. script_path())
end

function script_unload()
	print("Unloading script " .. script_path())
	cleanup_sock()
end

function script_save()
	--nop
end

function script_defaults(settings)
	obs.obs_data_set_default_bool(settings, "run", def_settings.run)
	obs.obs_data_set_default_int(settings, "port", def_settings.port)
	obs.obs_data_set_default_bool(settings, "debug", def_settings.debug)
end

function script_update(settings)
	print "Updating settings.."
	cur_settings.run = obs.obs_data_get_bool(settings, "run")
	cur_settings.debug = obs.obs_data_get_bool(settings, "debug")
	cur_settings.port = obs.obs_data_get_int(settings, "port")
	cur_settings.webroot = obs.obs_data_get_string(settings, "webroot") .. "/"
	for k,v in pairs(cur_settings) do
		debug_print("\t" .. k .. " => " .. tostring(v))
	end

	-- don't start listening if webroot hasn't been set yet
	if cur_settings.run and cur_settings.webroot then
		startup_sock()
	else
		cleanup_sock()
	end
end

function script_properties()
	local prop = obs.obs_properties_create()

	local enable = obs.obs_properties_add_bool(prop, "run", "Run Server?")
	local port = obs.obs_properties_add_int(prop, "port", "TCP listen port", 1024, 65353, 1)
	local webroot = obs.obs_properties_add_path(prop, "webroot", "Webroot directory", obs.OBS_PATH_DIRECTORY, "*.html", script_path())
	local debug = obs.obs_properties_add_bool(prop, "debug", "Log debugging messages?")

	return prop
end

function script_tick(seconds)
	-- per frame tick
end

function startup_sock()
	if sock then
		print "Socket wasn't cleaned up, cleaning..."
		cleanup_sock()
	end
	print "Starting listening..."
	sock = assert(socket.create("inet", "stream", "tcp"))
	assert(sock:set_blocking(false)) -- critical! don't hang obs UI!
	assert(sock:set_option("reuseaddr", true))
	assert(sock:bind(bind_host, cur_settings.port))
	assert(sock:listen())
	debug_print("\tlistening on " .. tostring(sock))

	obs.timer_add(do_slow_poll, poll_interval)
	do_poll() -- no delay for testing
end

function cleanup_sock()
	print "Stopping listening..."
	if sock then
		assert(sock:close())
		sock = nil
	end
end

function do_slow_poll()
	do_poll()
end

local fast_poll = false
local idle_count = 0
function do_fast_poll()
	idle_count = idle_count + 1
	if idle_count > max_fast_idle then
		obs.remove_current_callback()
		fast_poll = false
	else
		do_poll()
	end
end

function do_poll()
	if sock == nil then
		obs.remove_current_callback()
		return
	end
	local client, err, errno = sock:accept()

	if client and client:is_connected() then
		idle_count = 0
		if not fast_poll then
			fast_poll = true
			obs.timer_add(do_fast_poll, poll_interval_fast)
		end
		debug_print("Got client " .. tostring(client))
		debug_print("\tName is " .. tostring(client:get_name()))
		debug_print("\tPeername is " .. tostring(client:get_peer_name()))
		assert(client:set_blocking(false)) -- critical! don't hang obs UI!
		do_request(client)
		client:close()
	elseif err ~= "timeout" then
		error(err)
	end
end

function hex_to_char(x)
  return string.char(tonumber(x, 16))
end

function url_decode(s)
  return string.gsub(s, "%%(%x%x)", hex_to_char)
end

local response_unconfig = [[
HTTP/1.1 200 OK
Connection: Close
Content-Type: text/html; charset=utf-8
Access-Control-Allow-Origin: *
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cache-Control: max-age=15

<div style="background-color: darkgrey; foreground-color: white">
<h1>Please configure your project location in the OBS scripts menu!</h1>
</div>
]]

local response_dummy_index = [[
HTTP/1.1 200 OK
Connection: Close
Content-Type: text/html; charset=utf-8
Access-Control-Allow-Origin: *
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cache-Control: max-age=15

<div style="background-color: darkgrey; foreground-color: white">
<h1>Success!</h1>
<h2>The OBS browser source httpd is running!</h2>
<p>But you don't have an index.html file.
Please point your browser source to an existing file.</p>
</div>
]]

local response_forbidden = [[
HTTP/1.1 403 Forbidden
Connection: Close
Content-Type: text/html; charset=utf-8
Access-Control-Allow-Origin: *
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cache-Control: max-age=15

<div style="background-color: darkgrey; foreground-color: white">
<h1>You cannot access this location, please check the script log and config.</h1>
</div>
]]

local response_404 = [[
HTTP/1.1 404 Not Found
Connection: Close
Content-Type: text/html; charset=utf-8
Access-Control-Allow-Origin: *
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cache-Control: max-age=15

<div style="background-color: darkgrey; foreground-color: white">
<h1>There was an error accessing this location, please check the script log.</h1>
</div>
]]

function do_request(client)
	local request_raw, err = client:receive()
	if not request_raw then
		if err ~= "timeout" then 
			error("Client read error: " .. err)
		else
			-- client probably closed the connection before we got to it
			print("Client socket timeout before processing")
		end
		return
	end
	local line = string.gmatch(request_raw, "[^\n]+")
	local method, url, ver = string.match(line(), "(%g+) (%g*) HTTP/(%g+)")
	url = url_decode(url)
	if method ~= "GET" then
		error("Error: client requested unsupported http method")
		return
	end
	if ver ~= "1.1" then
		error("Error: client requested unsupported http version")
		return
	end
	debug_print("\trequest for " .. url)

	if not cur_settings.webroot then
		-- shouldn't happen, but just incase
		error("Request received with webroot unconfigured")
		assert(client:send(response_unconfig))
		return
	end

	-- block paths containing "/../"
	-- which could allow access outside of the web directory
	if string.match(url, "/../") then
		error("Request attempted to enter a parent directory")
		assert(client:send(response_forbidden))
		return
	end
	
	if (url == "/") then
		url = "/index.html"
	end
	local filename, file_extension = string.match(url, "^/([^/]-)%.([^./]+)$")
	if filename and file_extension then
		filename = cur_settings.webroot .. filename .. "." .. file_extension
	else
		error("Request is not an allowed file")
		debug_print(string.format("\turl was '%s' and matched as '%s'<dot>'%s'", url, filename, file_extension))
		assert(client:send(response_forbidden))
		return
	end
	debug_print("\tmapped to " .. filename)
	debug_print("\textension is " .. file_extension)

	local content_type = content_type_mapping[file_extension]
	if not content_type then
		error("Unknown file extension: " .. file_extension)
		assert(client:send(response_forbidden))
		return
	end

	local file, err = io.open(filename, "rb")
	if not file then
		if url == "/index.html" then
			print("Warning: No index.html found, sending dummy index")
			assert(client:send(response_dummy_index))
		else
			error("Error opening file: " .. err)
			assert(client:send(response_404))
		end
		return
	end

	local content = file:read("*all")
	file:close()
	local content_length = string.len(content)

	local headers = string.format([[
HTTP/1.1 200 OK
Connection: Close
Content-Type: %s
Access-Control-Allow-Origin: *
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
Cache-Control: max-age=15

]], content_type)
	
	print(string.format("Serving request for %s from %s (%s, %dkB)", url, filename, content_type, content_length / 1024))
	client:send(headers);
	client:send(content);
end

