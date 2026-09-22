#include <sourcemod>
#include <SteamWorks>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo =
{
    name = "SteamWorks Stream Test",
    description = "Tests the SteamWorks streaming HTTP download API",
    author = "BadServers.net",
    version = "0.3.0",
    url = "https://badservers.net"
};

#define DEFAULT_URL "https://ash-speed.hetzner.com/1GB.bin"
#define OUTPUT_PATH "data/steamworks-stream-test.bin"
#define CHUNK_BUFFER_SIZE 1048576
#define PACK_BUFFER_SIZE 262144
#define BYTES_PER_MIB 1048576.0
#define STATUS_INTERVAL 0.5
#define NETWORK_TIMEOUT_SECONDS 60

ConVar g_cvUrl;
Handle g_hRequest;
File g_hOutputFile;
Handle g_hStatusTimer;
char g_sChunk[CHUNK_BUFFER_SIZE];
int g_iPack[PACK_BUFFER_SIZE];
int g_iBytesReceived;
int g_iContentLength;
int g_iChunkCount;
int g_iLastChunkSize;
float g_fStartTime;
bool g_bCompleted;
char g_sPhase[64];

public void OnPluginStart()
{
    g_cvUrl = CreateConVar("sm_streamtest_url", DEFAULT_URL, "URL of the test binary to download with the SteamWorks streaming API.");
    RegAdminCmd("sm_streamtest", Command_StreamTest, ADMFLAG_ROOT, "[url] Starts a streaming download of a test binary.");
    RegAdminCmd("sm_streamtest_cancel", Command_StreamTestCancel, ADMFLAG_ROOT, "Cancels the running streaming download.");
    RegAdminCmd("sm_streamtest_diag", Command_StreamTestDiag, ADMFLAG_ROOT, "Prints SteamWorks connection and HTTP interface diagnostics.");
}

public void OnPluginEnd()
{
    CleanupDownload();
}

public Action Command_StreamTest(int client, int args)
{
    if (g_hRequest != null)
    {
        ReplyToCommand(client, "[StreamTest] A download is already running. Use sm_streamtest_cancel first.");
        return Plugin_Handled;
    }

    char url[512];
    ResolveUrl(args, url, sizeof(url));

    char outputPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, outputPath, sizeof(outputPath), OUTPUT_PATH);

    g_hOutputFile = OpenFile(outputPath, "wb");

    if (g_hOutputFile == null)
    {
        ReplyToCommand(client, "[StreamTest] Failed to open %s for writing.", outputPath);
        return Plugin_Handled;
    }

    g_hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, url);

    if (g_hRequest == null)
    {
        CleanupDownload();
        ReplyToCommand(client, "[StreamTest] Failed to create the HTTP request.");
        return Plugin_Handled;
    }

    SteamWorks_SetHTTPRequestNetworkActivityTimeout(g_hRequest, NETWORK_TIMEOUT_SECONDS);
    SteamWorks_SetHTTPCallbacks(g_hRequest, OnRequestCompleted, OnHeadersReceived, OnDataReceived);

    ResetProgress();

    bool sent = SteamWorks_SendHTTPRequestAndStreamResponse(g_hRequest);

    if (!sent)
    {
        CleanupDownload();
        ReplyToCommand(client, "[StreamTest] SteamWorks_SendHTTPRequestAndStreamResponse failed.");
        return Plugin_Handled;
    }

    strcopy(g_sPhase, sizeof(g_sPhase), "Request sent, waiting for headers");
    g_hStatusTimer = CreateTimer(STATUS_INTERVAL, Timer_ShowStatus, _, TIMER_REPEAT);

    ReplyToCommand(client, "[StreamTest] Streaming download started: %s", url);
    LogMessage("[StreamTest] Streaming download started: %s -> %s", url, outputPath);
    ShowStatus();

    return Plugin_Handled;
}

public Action Command_StreamTestCancel(int client, int args)
{
    if (g_hRequest == null)
    {
        ReplyToCommand(client, "[StreamTest] No download is running.");
        return Plugin_Handled;
    }

    CleanupDownload();
    PrintHintTextToAll("<font color='#ff4040'>StreamTest cancelled</font>");
    ReplyToCommand(client, "[StreamTest] Download cancelled.");

    return Plugin_Handled;
}

public Action Command_StreamTestDiag(int client, int args)
{
    bool loaded = SteamWorks_IsLoaded();
    bool connected = SteamWorks_IsConnected();

    int ip[4];
    bool hasIp = SteamWorks_GetPublicIP(ip);

    Handle request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, "https://badservers.net/");
    bool created = request != null;
    delete request;

    ReplyToCommand(client, "[StreamTest] loaded=%d connected=%d publicIp=%d (%d.%d.%d.%d) httpRequestCreated=%d", loaded, connected, hasIp, ip[0], ip[1], ip[2], ip[3], created);

    return Plugin_Handled;
}

void ResolveUrl(int args, char[] url, int maxlength)
{
    if (args >= 1)
    {
        GetCmdArg(1, url, maxlength);
        return;
    }

    g_cvUrl.GetString(url, maxlength);
}

void ResetProgress()
{
    g_iBytesReceived = 0;
    g_iContentLength = 0;
    g_iChunkCount = 0;
    g_iLastChunkSize = 0;
    g_fStartTime = GetEngineTime();
    g_bCompleted = false;
}

public void OnHeadersReceived(Handle request, bool failure)
{
    if (g_bCompleted)
    {
        LogMessage("[StreamTest] Headers callback arrived after completion (failure=%d). Ignoring.", failure);
        return;
    }

    if (failure)
    {
        strcopy(g_sPhase, sizeof(g_sPhase), "Header callback reported failure");
        ShowStatus();
        return;
    }

    char contentLength[32];
    bool hasContentLength = SteamWorks_GetHTTPResponseHeaderValue(request, "Content-Length", contentLength, sizeof(contentLength));

    if (hasContentLength)
    {
        g_iContentLength = StringToInt(contentLength);
    }

    float contentMiB = ToMiB(g_iContentLength);

    strcopy(g_sPhase, sizeof(g_sPhase), "Headers received, streaming body");
    LogMessage("[StreamTest] Headers received. Content-Length: %d (%.2f MiB)", g_iContentLength, contentMiB);
    ShowStatus();
}

public void OnDataReceived(Handle request, bool failure, int offset, int bytesReceived)
{
    if (g_bCompleted)
    {
        LogMessage("[StreamTest] Data callback arrived after completion (failure=%d offset=%d bytes=%d). Ignoring.", failure, offset, bytesReceived);
        return;
    }

    if (failure)
    {
        strcopy(g_sPhase, sizeof(g_sPhase), "Data callback reported failure");
        ShowStatus();
        return;
    }

    if (g_hOutputFile == null)
    {
        return;
    }

    WriteChunkToFile(request, offset, bytesReceived);

    g_iBytesReceived += bytesReceived;
    g_iChunkCount++;
    g_iLastChunkSize = bytesReceived;

    strcopy(g_sPhase, sizeof(g_sPhase), "Streaming body to disk");
    ShowStatus();
}

void WriteChunkToFile(Handle request, int chunkOffset, int chunkSize)
{
    if (chunkSize > CHUNK_BUFFER_SIZE)
    {
        LogError("[StreamTest] Chunk of %d bytes at offset %d exceeds the %d byte buffer. Skipping.", chunkSize, chunkOffset, CHUNK_BUFFER_SIZE);
        return;
    }

    bool read = SteamWorks_GetHTTPStreamingResponseBodyData(request, chunkOffset, g_sChunk, chunkSize);

    if (!read)
    {
        LogError("[StreamTest] GetHTTPStreamingResponseBodyData failed at offset %d (%d bytes).", chunkOffset, chunkSize);
        return;
    }

    WriteSliceToFile(chunkSize);
}

void WriteSliceToFile(int sliceSize)
{
    int wholeCells = sliceSize / 4;
    int trailingBytes = sliceSize % 4;

    for (int cell = 0; cell < wholeCells; cell++)
    {
        int byteIndex = cell * 4;
        g_iPack[cell] = PackCell(byteIndex);
    }

    if (wholeCells > 0)
    {
        g_hOutputFile.Write(g_iPack, wholeCells, 4);
    }

    int trailingStart = wholeCells * 4;

    for (int index = 0; index < trailingBytes; index++)
    {
        int byteValue = g_sChunk[trailingStart + index] & 0xFF;
        g_hOutputFile.WriteInt8(byteValue);
    }
}

int PackCell(int byteIndex)
{
    int byte0 = g_sChunk[byteIndex] & 0xFF;
    int byte1 = g_sChunk[byteIndex + 1] & 0xFF;
    int byte2 = g_sChunk[byteIndex + 2] & 0xFF;
    int byte3 = g_sChunk[byteIndex + 3] & 0xFF;

    return byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24);
}

public void OnRequestCompleted(Handle request, bool failure, bool requestSuccessful, EHTTPStatusCode statusCode)
{
    float elapsed = GetEngineTime() - g_fStartTime;
    int fileSize = FinishOutputFile();

    bool timedOut = false;
    SteamWorks_GetHTTPRequestWasTimedOut(request, timedOut);

    g_bCompleted = true;
    delete g_hStatusTimer;
    RequestFrame(Frame_ReleaseRequest);

    float receivedMiB = ToMiB(g_iBytesReceived);
    float contentMiB = ToMiB(g_iContentLength);
    float speed = CalculateSpeedMBps(receivedMiB, elapsed);

    if (failure || !requestSuccessful)
    {
        char timedOutLabel[8];
        YesNo(timedOut, timedOutLabel, sizeof(timedOutLabel));

        LogError("[StreamTest] Download failed. failure=%d successful=%d status=%d timedOut=%d received=%d chunks=%d elapsed=%.2fs", failure, requestSuccessful, statusCode, timedOut, g_iBytesReceived, g_iChunkCount, elapsed);
        PrintHintTextToAll("<font color='#ff4040'>StreamTest FAILED</font><br>HTTP status: %d<br>Timed out: %s<br>Received: %.2f MiB in %d chunks<br>Time: %.1fs", statusCode, timedOutLabel, receivedMiB, g_iChunkCount, elapsed);
        return;
    }

    bool sizeMatches = g_iContentLength == 0 || g_iContentLength == g_iBytesReceived;
    bool fileMatches = fileSize == g_iBytesReceived;

    char sizeMatchLabel[8];
    YesNo(sizeMatches, sizeMatchLabel, sizeof(sizeMatchLabel));

    char fileMatchLabel[8];
    YesNo(fileMatches, fileMatchLabel, sizeof(fileMatchLabel));

    LogMessage("[StreamTest] Download complete. status=%d received=%d contentLength=%d fileSize=%d chunks=%d elapsed=%.2fs speed=%.2fMB/s", statusCode, g_iBytesReceived, g_iContentLength, fileSize, g_iChunkCount, elapsed, speed);
    PrintHintTextToAll("<font color='#40ff40'>StreamTest COMPLETE</font><br>HTTP status: %d<br>Received: %.2f / %.2f MiB in %d chunks<br>File on disk: %d bytes (match: %s)<br>Matches Content-Length: %s<br>Time: %.1fs (%.2f MB/s)", statusCode, receivedMiB, contentMiB, g_iChunkCount, fileSize, fileMatchLabel, sizeMatchLabel, elapsed, speed);
}

void YesNo(bool value, char[] buffer, int maxlength)
{
    if (value)
    {
        strcopy(buffer, maxlength, "yes");
        return;
    }

    strcopy(buffer, maxlength, "NO");
}

void Frame_ReleaseRequest(any data)
{
    delete g_hRequest;
}

int FinishOutputFile()
{
    if (g_hOutputFile == null)
    {
        return 0;
    }

    delete g_hOutputFile;

    char outputPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, outputPath, sizeof(outputPath), OUTPUT_PATH);

    int fileSize = FileSize(outputPath);

    return fileSize;
}

public Action Timer_ShowStatus(Handle timer)
{
    if (g_hRequest == null)
    {
        g_hStatusTimer = null;
        return Plugin_Stop;
    }

    ShowStatus();

    return Plugin_Continue;
}

void ShowStatus()
{
    if (g_hRequest == null || g_bCompleted)
    {
        return;
    }

    float elapsed = GetEngineTime() - g_fStartTime;
    float receivedMiB = ToMiB(g_iBytesReceived);
    float speed = CalculateSpeedMBps(receivedMiB, elapsed);
    float steamPercent = 0.0;
    SteamWorks_GetHTTPDownloadProgressPct(g_hRequest, steamPercent);

    char sizeLine[96];
    FormatSizeLine(receivedMiB, sizeLine, sizeof(sizeLine));

    PrintHintTextToAll("<font color='#ffd700'>StreamTest</font> <font color='#a0a0a0'>%s</font><br>%s<br>Chunks: %d (last %d bytes)<br>Steam progress: %.1f%%<br>Time: %.1fs (%.2f MB/s)", g_sPhase, sizeLine, g_iChunkCount, g_iLastChunkSize, steamPercent, elapsed, speed);
}

void FormatSizeLine(float receivedMiB, char[] buffer, int maxlength)
{
    if (g_iContentLength <= 0)
    {
        Format(buffer, maxlength, "Received: %.2f MiB", receivedMiB);
        return;
    }

    float contentMiB = ToMiB(g_iContentLength);
    float percent = receivedMiB / contentMiB * 100.0;

    Format(buffer, maxlength, "Received: %.2f / %.2f MiB (%.1f%%)", receivedMiB, contentMiB, percent);
}

float ToMiB(int bytes)
{
    return float(bytes) / BYTES_PER_MIB;
}

float CalculateSpeedMBps(float megabytes, float elapsed)
{
    if (elapsed <= 0.0)
    {
        return 0.0;
    }

    return megabytes / elapsed;
}

void CleanupDownload()
{
    delete g_hStatusTimer;
    delete g_hRequest;
    delete g_hOutputFile;
}
