# steamworks-stream-test

Test plugin for the SteamWorks streaming HTTP download API. Not intended for production use.

## How it works

`sm_streamtest [url]` creates a GET request, registers completed, headers, and data callbacks, and sends it with `SteamWorks_SendHTTPRequestAndStreamResponse`. Each data callback reads the chunk with `SteamWorks_GetHTTPStreamingResponseBodyData` and appends it to `addons/sourcemod/data/steamworks-stream-test.bin`. Progress is shown to everyone with HTML hint text every half second and on every chunk. On completion the hint text reports the HTTP status, bytes received, chunk count, on-disk file size, whether it matches `Content-Length`, and throughput.

## Commands

| Command | What it does | Access |
| --- | --- | --- |
| `sm_streamtest [url]` | Starts a streaming download of the given URL or `sm_streamtest_url`. | Root |
| `sm_streamtest_cancel` | Cancels the running download. | Root |

## ConVars

| ConVar | Default | What it does |
| --- | --- | --- |
| `sm_streamtest_url` | `https://ash-speed.hetzner.com/1GB.bin` | Default test binary URL (1 GB). |

## Requirements

- SteamWorks extension.

## Extension requirement

This plugin targets the AlliedModders fork of SteamWorks (https://github.com/alliedmodders/SM-SteamWorks). The original KyleS extension binds `HTTPRequestHeadersReceived_t` and `HTTPRequestDataReceived_t` as call results on the completion call, so its headers and data forwards fire with the completion payload and streaming never delivers chunks. The fork routes them as broadcast callbacks and works.

The fork's published `v1.2.163` binary requests `SteamClient023`, but the CS:GO dedicated server's bundled `bin/steamclient.so` only exposes up to `SteamClient020`, so the release build never attaches to Steam (`SteamWorks_IsLoaded` returns false and every HTTP native fails). `ISteamClient::GetISteamHTTP` also sits at a different vtable slot in `SteamClient020`, so a plain name fallback is not enough.

Use the BadServersNet build from https://github.com/BadServersNet/sm-steamworks/releases instead. It falls back through older `SteamClient` versions (or a `SteamClientInterfaceVersion` gamedata key), fetches `ISteamHTTP` through the version-stable `GetISteamGenericInterface`, and falls back to `SteamUtils010`. Install the SourceMod 1.12 Linux package's `addons/sourcemod/extensions/SteamWorks.ext.so` and restart the server. `include/SteamWorks.inc` in this repository is the fork's include.

## Test results

With the patched extension on Dev CSGO, `sm_streamtest` streamed the 1 GiB Hetzner file to disk in 18805 chunks in 148 s (about 6.9 MB/s), and the received byte count, `Content-Length`, and on-disk file size all matched. The SHA-256 of the streamed file matched a direct download of the same file.

Pass URLs from the server console in quotes; the Source console tokenizer splits on `:` otherwise.
