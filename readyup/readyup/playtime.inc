#if defined _readyup_playtime_included
 #endinput
#endif
#define _readyup_playtime_included

// SteamWorks game-stat lookup. No bans, kicks, database, or network calls on panel refresh.
// Requires the SteamWorks extension; this is not an optional native dependency.
#define READYUP_PLAYTIME_APPID 550
#define READYUP_PLAYTIME_MAX_ATTEMPTS 60

static int g_ReadyupPlaytimeSeconds[MAXPLAYERS + 1];
static bool g_ReadyupPlaytimeKnown[MAXPLAYERS + 1];
static int g_ReadyupPlaytimeAttempts[MAXPLAYERS + 1];
static Handle g_ReadyupPlaytimeTimer[MAXPLAYERS + 1];
static int g_ReadyupPlaytimeUserID[MAXPLAYERS + 1];
static ConVar g_ReadyupPlaytimeEnabled;
static char g_ReadyupAuthScratch[32];

void InitReadyupPlaytime()
{
    g_ReadyupPlaytimeEnabled = CreateConVar(
        "l4d_ready_show_playtime", "1",
        "Show Steam game-stat playtime after ReadyUp player names.",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    // Support late plugin loads; OnClientPostAdminCheck won't replay for existing clients.
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client) &&
            GetClientAuthId(client, AuthId_Steam2, g_ReadyupAuthScratch, sizeof(g_ReadyupAuthScratch)))
        {
            ReadyupPlaytime_Join(client);
        }
    }
}

void ReadyupPlaytime_StopTimer(int client)
{
    if (g_ReadyupPlaytimeTimer[client] != null)
    {
        delete g_ReadyupPlaytimeTimer[client];
        g_ReadyupPlaytimeTimer[client] = null;
    }
}

void ReadyupPlaytime_Leave(int client)
{
    if (client < 1 || client > MaxClients)
        return;

    ReadyupPlaytime_StopTimer(client);
    g_ReadyupPlaytimeUserID[client] = 0;
    g_ReadyupPlaytimeSeconds[client] = 0;
    g_ReadyupPlaytimeKnown[client] = false;
    g_ReadyupPlaytimeAttempts[client] = 0;
}

// The repeating timer is intentionally allowed to span a map change.
// Connected players do not receive OnClientPostAdminCheck again after a map
// change. Stopping the timer here would permanently abandon their first query.
void ReadyupPlaytime_MapEnd()
{
    // No work needed: userid verification continues on every timer tick.
}

void ReadyupPlaytime_Join(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) ||
        IsFakeClient(client) || g_ReadyupPlaytimeEnabled == null ||
        !g_ReadyupPlaytimeEnabled.BoolValue)
        return;

    int userid = GetClientUserId(client);
    if (userid <= 0 || g_ReadyupPlaytimeUserID[client] == userid)
        return;

    ReadyupPlaytime_Leave(client);
    g_ReadyupPlaytimeUserID[client] = userid;

    // One timer per connection, no Steam calls from UpdatePanel().
    g_ReadyupPlaytimeTimer[client] = CreateTimer(
        2.0, ReadyupPlaytime_Retry, userid, TIMER_REPEAT
    );
}

Action ReadyupPlaytime_Retry(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0)
        return Plugin_Stop;

    if (g_ReadyupPlaytimeTimer[client] != timer ||
        g_ReadyupPlaytimeUserID[client] != userid)
        return Plugin_Stop;

    if (!IsClientInGame(client) || IsFakeClient(client) ||
        !g_ReadyupPlaytimeEnabled.BoolValue ||
        g_ReadyupPlaytimeKnown[client])
    {
        g_ReadyupPlaytimeTimer[client] = null;
        return Plugin_Stop;
    }

    // Poll for up to 120 seconds (60 ticks), but request stats only
    // once every 20 seconds (6 requests maximum). SteamWorks may make
    // a previous request's data available well after its initial return.
    g_ReadyupPlaytimeAttempts[client]++;

    if (g_ReadyupPlaytimeAttempts[client] > 60)
    {
        g_ReadyupPlaytimeTimer[client] = null;
        return Plugin_Stop;
    }

    if (g_ReadyupPlaytimeAttempts[client] % 10 == 1)
        SteamWorks_RequestStats(client, READYUP_PLAYTIME_APPID);

    int seconds = -1;
    if (SteamWorks_GetStatCell(client, "Stat.TotalPlayTime.Total", seconds) &&
        seconds >= 0)
    {
        g_ReadyupPlaytimeSeconds[client] = seconds;
        g_ReadyupPlaytimeKnown[client] = true;
        g_ReadyupPlaytimeTimer[client] = null;
        return Plugin_Stop;
    }

    if (g_ReadyupPlaytimeAttempts[client] >= 60)
    {
        g_ReadyupPlaytimeTimer[client] = null;
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

void ReadyupPlaytime_Append(int client, char[] name, int maxlen)
{
    if (client < 1 || client > MaxClients ||
        g_ReadyupPlaytimeEnabled == null || !g_ReadyupPlaytimeEnabled.BoolValue)
        return;

    char suffix[24];
    if (g_ReadyupPlaytimeKnown[client])
        FormatEx(suffix, sizeof(suffix), "[%dh]", g_ReadyupPlaytimeSeconds[client] / 3600);
    else
        strcopy(suffix, sizeof(suffix), "[--h]");

    // Leave room for ready symbol and AFK tag added by panel.inc afterwards.
    // Truncate only at UTF-8 code-point boundaries.
    int limit = maxlen - strlen(suffix) - 12;
    if (limit <= 0)
        return;
    int n = strlen(name);
    if (n > limit)
    {
        n = limit;
        while (n > 0 && (name[n] & 0xC0) == 0x80)
            n--;
        name[n] = '\0';
    }
    StrCat(name, maxlen, suffix);
}
