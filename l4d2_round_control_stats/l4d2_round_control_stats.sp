#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <multicolors>

#define PLUGIN_VERSION "1.3.1"

enum StatType
{
    Stat_Hunter = 0,
    Stat_Smoker,
    Stat_Jockey,
    Stat_Charger,
    Stat_TankPunch,
    Stat_TankRock,
    Stat_Count
};

int g_Stats[MAXPLAYERS + 1][Stat_Count];
bool g_bPrinted;
bool g_bPrintPending;
int g_RoundSerial;
int g_EndCount;
char g_EndNames[4][MAX_NAME_LENGTH];
int g_EndStats[4][Stat_Count];
ConVar g_cvGameMode;

float g_LastChargeHit[MAXPLAYERS + 1][MAXPLAYERS + 1];

int g_SmokerGrabSerial[MAXPLAYERS + 1];
bool g_HasPullEvent;

public Plugin myinfo =
{
    name = "L4D2 Round Control Stats",
    author = "Ts & UUZ",
    description = "统计生还被控次数",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_cvGameMode = FindConVar("mp_gamemode");
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("mission_lost", Event_RoundEnd, EventHookMode_PostNoCopy);
    HookEvent("lunge_pounce", Event_Hunter);
    
    g_HasPullEvent = HookEventEx("tongue_pull_started", Event_Smoker);
    if (!g_HasPullEvent)
        HookEvent("tongue_grab", Event_SmokerGrab);
    HookEvent("jockey_ride", Event_Jockey);
    HookEvent("charger_carry_start", Event_ChargerHit);
    HookEventEx("charger_impact", Event_ChargerHit);
    HookEvent("player_hurt", Event_PlayerHurt);
    ResetRound();
}

public void OnMapStart()
{
    ResetRound();
}

public void OnMapEnd()
{
    PrintPendingRoundStats();
}

public void OnClientDisconnect(int client)
{
    ClearClient(client);
    g_SmokerGrabSerial[client]++;
    for (int i = 1; i <= MaxClients; i++)
    {
        g_LastChargeHit[client][i] = 0.0;
        g_LastChargeHit[i][client] = 0.0;
    }
}

void ClearClient(int client)
{
    for (int i = 0; i < view_as<int>(Stat_Count); i++)
        g_Stats[client][i] = 0;
}

void ResetRound()
{
    // A fast half change must not erase an end-of-round snapshot before
    // its delayed print runs. Old timers are rejected by the round serial.
    PrintPendingRoundStats();
    g_bPrinted = false;
    g_RoundSerial++;
    g_EndCount = 0;
    for (int client = 1; client <= MaxClients; client++)
    {
        ClearClient(client);
        g_SmokerGrabSerial[client]++;
        for (int victim = 1; victim <= MaxClients; victim++)
            g_LastChargeHit[client][victim] = 0.0;
    }
}

bool IsVersus()
{
    if (g_cvGameMode == null)
        return false;

    char mode[64];
    g_cvGameMode.GetString(mode, sizeof(mode));
    return StrContains(mode, "versus", false) != -1;
}

bool IsHumanSurvivor(int client)
{
    return client >= 1 && client <= MaxClients && IsClientInGame(client)
        && !IsFakeClient(client) && GetClientTeam(client) == 2;
}

void AddVictimStat(Event event, StatType stat)
{
    if (g_bPrinted || !IsVersus())
        return;

    int victim = GetClientOfUserId(event.GetInt("victim"));
    if (IsHumanSurvivor(victim))
        g_Stats[victim][stat]++;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    ResetRound();
}

public void Event_Hunter(Event event, const char[] name, bool dontBroadcast)
{
    AddVictimStat(event, Stat_Hunter);
}

public void Event_Smoker(Event event, const char[] name, bool dontBroadcast)
{
    AddVictimStat(event, Stat_Smoker);
}

public void Event_Jockey(Event event, const char[] name, bool dontBroadcast)
{
    AddVictimStat(event, Stat_Jockey);
}

public void Event_SmokerGrab(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bPrinted || !IsVersus())
        return;
    int victim = GetClientOfUserId(event.GetInt("victim"));
    int smoker = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHumanSurvivor(victim) || smoker < 1 || smoker > MaxClients)
        return;
    int serial = ++g_SmokerGrabSerial[victim];
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(victim));
    pack.WriteCell(GetClientUserId(smoker));
    pack.WriteCell(serial);
    CreateTimer(0.5, Timer_CheckSmokerDrag, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
}

public Action Timer_CheckSmokerDrag(Handle timer, DataPack pack)
{
    pack.Reset();
    int victim = GetClientOfUserId(pack.ReadCell());
    int smoker = GetClientOfUserId(pack.ReadCell());
    int serial = pack.ReadCell();
    if (g_bPrinted || !IsVersus() || !IsHumanSurvivor(victim)
        || smoker < 1 || smoker > MaxClients || !IsClientInGame(smoker)
        || serial != g_SmokerGrabSerial[victim])
        return Plugin_Stop;

    if (!HasEntProp(victim, Prop_Send, "m_tongueOwner")
        || GetEntPropEnt(victim, Prop_Send, "m_tongueOwner") != smoker)
        return Plugin_Stop;
    if (HasEntProp(victim, Prop_Send, "m_isHangingFromTongue")
        && GetEntProp(victim, Prop_Send, "m_isHangingFromTongue") != 0)
        return Plugin_Stop;
    g_Stats[victim][Stat_Smoker]++;
    return Plugin_Stop;
}

public void Event_ChargerHit(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bPrinted || !IsVersus())
        return;

    int victim = GetClientOfUserId(event.GetInt("victim"));
    if (!IsHumanSurvivor(victim))
        return;

    int charger = GetClientOfUserId(event.GetInt("userid"));
    if (charger < 1 || charger > MaxClients)
    {
        g_Stats[victim][Stat_Charger]++;
        return;
    }
    float now = GetGameTime();
    if (now - g_LastChargeHit[charger][victim] < 1.5)
        return;
    g_LastChargeHit[charger][victim] = now;
    g_Stats[victim][Stat_Charger]++;
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bPrinted || !IsVersus() || event.GetInt("dmg_health") <= 0)
        return;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (!IsHumanSurvivor(victim))
        return;

    char weapon[64];
    event.GetString("weapon", weapon, sizeof(weapon));

    if (StrEqual(weapon, "tank_claw", false))
        g_Stats[victim][Stat_TankPunch]++;
    else if (StrEqual(weapon, "tank_rock", false))
        g_Stats[victim][Stat_TankRock]++;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    FinishRound();
}

// Optional forward: provides a versus-specific end signal when Left4DHooks
// is installed. No new include or required native dependency is introduced.
public void L4D2_OnEndVersusModeRound_Post()
{
    FinishRound();
}

void FinishRound()
{
    if (g_bPrinted || !IsVersus())
        return;

    g_bPrinted = true;
    g_EndCount = 0;
    for (int client = 1; client <= MaxClients && g_EndCount < 4; client++)
    {
        if (!IsHumanSurvivor(client))
            continue;

        int slot = g_EndCount++;
        GetClientName(client, g_EndNames[slot], sizeof(g_EndNames[]));
        for (int stat = 0; stat < view_as<int>(Stat_Count); stat++)
            g_EndStats[slot][stat] = g_Stats[client][stat];
    }

    g_bPrintPending = true;
    CreateTimer(2.0, Timer_PrintRoundStats, g_RoundSerial, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_PrintRoundStats(Handle timer, any serial)
{
    if (serial != g_RoundSerial)
        return Plugin_Stop;

    PrintPendingRoundStats();
    return Plugin_Stop;
}

void PrintPendingRoundStats()
{
    if (!g_bPrintPending)
        return;

    g_bPrintPending = false;
    for (int slot = 0; slot < g_EndCount; slot++)
    {
        CPrintToChatAll("{green}%s: {default}[{red}被扑 {olive}%d{default} ][{red}被拉 {olive}%d{default} ][{red}被骑 {olive}%d{default} ][{red}被撞 {olive}%d{default} ][{red}吃拳 {olive}%d{default} ][{red}吃饼 {olive}%d{default} ]",
            g_EndNames[slot],
            g_EndStats[slot][Stat_Hunter],
            g_EndStats[slot][Stat_Smoker],
            g_EndStats[slot][Stat_Jockey],
            g_EndStats[slot][Stat_Charger],
            g_EndStats[slot][Stat_TankPunch],
            g_EndStats[slot][Stat_TankRock]);
    }
}
