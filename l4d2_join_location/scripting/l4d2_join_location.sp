#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <geoip>
#include <multicolors>

#define VERSION "1.4.0"
#define JOIN_RETRY_INTERVAL 2.0
#define JOIN_MAX_RETRIES 15

ConVar g_Delay;
bool g_InGame[MAXPLAYERS + 1];
bool g_Authorized[MAXPLAYERS + 1];
bool g_Announced[MAXPLAYERS + 1];
int g_RetryAttempts[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "L4D2 Join Location and SteamID64",
    author = "Ts & UUZ",
    description = "参考Love平台做的显示玩家连接退出及64位ID",
    version = VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_Delay = CreateConVar("l4d2_join_location_delay", "6.0", "Seconds after the player is in game and Steam authorization is complete", FCVAR_NONE, true, 0.0, true, 30.0);
    RegConsoleCmd("sm_joininfo", Command_JoinInfo, "Show your own location and SteamID64");
    AutoExecConfig(true, "l4d2_join_location");
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client))
        {
            g_InGame[client] = true;
            g_Authorized[client] = true;
            g_Announced[client] = true;
        }
    }
}

public void OnClientConnected(int client)
{
    g_InGame[client] = false;
    g_Authorized[client] = false;
    g_Announced[client] = false;
    g_RetryAttempts[client] = 0;
}

public void Event_PlayerDisconnect(Event event, const char[] eventName, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    if (client < 1 || client > MaxClients || !g_InGame[client] || IsFakeClient(client))
        return;

    char playerName[MAX_NAME_LENGTH];
    char reason[192];
    event.GetString("name", playerName, sizeof(playerName));
    event.GetString("reason", reason, sizeof(reason));

    if (playerName[0] == '\0')
        GetClientName(client, playerName, sizeof(playerName));
    if (reason[0] == '\0')
        strcopy(reason, sizeof(reason), "未知原因");

    TranslateDisconnectReason(reason, sizeof(reason));

    ReplaceString(playerName, sizeof(playerName), "{", "(");
    ReplaceString(playerName, sizeof(playerName), "}", ")");
    ReplaceString(reason, sizeof(reason), "{", "(");
    ReplaceString(reason, sizeof(reason), "}", ")");
    ReplaceString(reason, sizeof(reason), "\n", " ");
    ReplaceString(reason, sizeof(reason), "\r", " ");

    CPrintToChatAll("玩家 {red}%s{default} 已离开服务器！[{olive}原因：%s{default}]", playerName, reason);
    LogMessage("Disconnect announcement sent: userid %d, name %s, reason %s", userid, playerName, reason);
}

void TranslateDisconnectReason(char[] reason, int size)
{
    if (reason[0] == '\0')
    {
        strcopy(reason, size, "未知原因");
        return;
    }

    if (StrEqual(reason, "Disconnect by user.", false)
        || StrEqual(reason, "Disconnect by user", false)
        || StrEqual(reason, "Client left game (Disconnect by user.)", false))
        strcopy(reason, size, "玩家主动断开连接");
    else if (StrContains(reason, "timed out", false) != -1
        || StrContains(reason, "timeout", false) != -1)
        strcopy(reason, size, "连接超时");
    else if (StrEqual(reason, "Kicked by Console", false)
        || StrEqual(reason, "Kicked by Console :", false))
        strcopy(reason, size, "被服务器踢出");
    else if (StrContains(reason, "Steam auth ticket has been canceled", false) != -1)
        strcopy(reason, size, "Steam 身份验证凭据已失效");
    else if (StrContains(reason, "No Steam logon", false) != -1)
        strcopy(reason, size, "Steam 登录连接已断开");
    else if (StrContains(reason, "Steam validation rejected", false) != -1)
        strcopy(reason, size, "Steam 身份验证失败");
    else if (StrContains(reason, "Steam account is being used in another location", false) != -1)
        strcopy(reason, size, "Steam 账号在其他位置登录");
    else if (StrContains(reason, "Lost connection to Steam servers", false) != -1)
        strcopy(reason, size, "与 Steam 服务器失去连接");
    else if (StrContains(reason, "Server shutting down", false) != -1
        || StrContains(reason, "Server is shutting down", false) != -1)
        strcopy(reason, size, "服务器正在关闭");
    else if (StrContains(reason, "Server is full", false) != -1)
        strcopy(reason, size, "服务器已满");
    else if (StrContains(reason, "Banned", false) != -1)
        strcopy(reason, size, "被服务器封禁");
    else if (StrContains(reason, "Kicked by administrator", false) != -1)
        strcopy(reason, size, "被管理员踢出");
    else if (StrContains(reason, "Kicked by Console", false) != -1)
        strcopy(reason, size, "被服务器踢出");
    else if (StrContains(reason, "Connection rejected", false) != -1)
        strcopy(reason, size, "连接被拒绝");
    else if (StrContains(reason, "Invalid SteamID", false) != -1)
        strcopy(reason, size, "SteamID 无效");
}

public void OnClientDisconnect(int client)
{
    g_InGame[client] = false;
    g_Authorized[client] = false;
    g_Announced[client] = false;
    g_RetryAttempts[client] = 0;
}

public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client))
        return;

    g_InGame[client] = true;
    TryScheduleJoin(client);
}

public void OnClientPostAdminCheck(int client)
{
    if (IsFakeClient(client))
        return;

    g_Authorized[client] = true;
    TryScheduleJoin(client);
}

void TryScheduleJoin(int client)
{
    if (!g_InGame[client] || !g_Authorized[client] || g_Announced[client] || !IsClientInGame(client))
        return;

    g_Announced[client] = true;
    int userid = GetClientUserId(client);
    CreateTimer(g_Delay.FloatValue, Timer_Announce, userid, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Announce(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Stop;

    char message[512];
    if (!BuildJoinMessage(client, message, sizeof(message)))
    {
        CreateTimer(JOIN_RETRY_INTERVAL, Timer_Retry, userid, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }

    CPrintToChatAll("%s", message);
    LogMessage("Join announcement sent: %s", message);

    return Plugin_Stop;
}

public Action Timer_Retry(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Stop;

    char message[512];
    if (BuildJoinMessage(client, message, sizeof(message)))
    {
        g_RetryAttempts[client] = 0;
        CPrintToChatAll("%s", message);
        LogMessage("Join announcement sent: %s", message);
        return Plugin_Stop;
    }

    g_RetryAttempts[client]++;
    if (g_RetryAttempts[client] >= JOIN_MAX_RETRIES)
    {
        g_RetryAttempts[client] = 0;
        LogMessage("Join announcement skipped: SteamID64 unavailable for userid %d", userid);
        return Plugin_Stop;
    }
    CreateTimer(JOIN_RETRY_INTERVAL, Timer_Retry, userid, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

public Action Command_JoinInfo(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Handled;

    char message[512];
    if (BuildJoinMessage(client, message, sizeof(message)))
        CPrintToChat(client, "%s", message);
    else
        CPrintToChat(client, "[JoinInfo] SteamID64 尚未获取成功，请稍后重试。");
    return Plugin_Handled;
}

bool BuildJoinMessage(int client, char[] message, int size)
{
    char steamid[32];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamid, sizeof(steamid), true) || steamid[0] == '\0')
        return false;

    char ip[64], country[128], city[128], name[MAX_NAME_LENGTH];
    GetClientIP(client, ip, sizeof(ip), true);
    GetClientName(client, name, sizeof(name));
    strcopy(country, sizeof(country), "未知国家");
    strcopy(city, sizeof(city), "未知城市");
    if (ip[0] != '\0')
    {
        if (!GeoipCountryEx(ip, country, sizeof(country), LANG_SERVER) || country[0] == '\0')
            strcopy(country, sizeof(country), "未知国家");
        if (!GeoipCity(ip, city, sizeof(city), LANG_SERVER) || city[0] == '\0')
            strcopy(city, sizeof(city), "未知城市");
    }

    Format(message, size, "玩家 {blue}%s{default} 已进入服务器！({olive}%s，%s{default}) [{green}%s{default}]", name, country, city, steamid);
    return true;
}
