#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "0.3.0"

enum HordeSource
{
    HordeSource_Unknown = 0,
    HordeSource_AlarmCar
};

ConVar g_cvEnable, g_cvStart, g_cvEnd, g_cvQuiet, g_cvDebug, g_cvAlarmWindow;

bool g_bActive;
int g_iAccepted, g_iSpawned;
float g_fLastRequest;
Handle g_hTimer = null;

float g_fLastAlarmTime;
int g_iLastAlarmUserId;
HordeSource g_Source;

public Plugin myinfo =
{
    name = "L4D2 Horde Counter",
    author = "Ts & UUZ",
    description = "Counts hordes",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    LoadTranslations("l4d2_horde_counter.phrases");

    g_cvEnable = CreateConVar("l4d2_horde_counter_enable", "1", "Enable plugin.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvStart = CreateConVar("l4d2_horde_counter_announce_start", "1", "Announce horde start.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvEnd = CreateConVar("l4d2_horde_counter_announce_end", "1", "Announce horde result.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvQuiet = CreateConVar("l4d2_horde_counter_quiet_time", "12.0", "Seconds without another accepted SpawnMob request before ending.", FCVAR_NOTIFY, true, 3.0, true, 60.0);
    g_cvAlarmWindow = CreateConVar("l4d2_horde_counter_alarm_window", "8.0", "Seconds after triggered_car_alarm in which the next horde is classified as alarm-car.", FCVAR_NOTIFY, true, 1.0, true, 30.0);
    g_cvDebug = CreateConVar("l4d2_horde_counter_debug", "0", "Diagnostic logging.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    HookEvent("triggered_car_alarm", Event_CarAlarm, EventHookMode_Post);
    HookEvent("round_start", Event_Reset, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_Reset, EventHookMode_PostNoCopy);
    HookEvent("map_transition", Event_Reset, EventHookMode_PostNoCopy);

    AutoExecConfig(true, "l4d2_horde_counter");
}

public void OnMapStart() { ResetAll(); }
public void OnMapEnd() { ResetAll(); }

public void Event_Reset(Event event, const char[] name, bool dontBroadcast)
{
    ResetAll();
}

public void Event_CarAlarm(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
        return;

    g_fLastAlarmTime = GetGameTime();
    g_iLastAlarmUserId = event.GetInt("userid");

    if (g_cvDebug.BoolValue)
        LogMessage("[HordeCounter] triggered_car_alarm userid=%d", g_iLastAlarmUserId);
}

public void L4D_OnSpawnMob_Post(int amount)
{
    if (!g_cvEnable.BoolValue || amount <= 0)
        return;

    if (!g_bActive)
    {
        g_bActive = true;
        g_iAccepted = 0;
        g_iSpawned = 0;
        g_Source = DetectSource();

        if (g_cvStart.BoolValue)
            AnnounceStart(amount);
    }

    g_iAccepted += amount;
    g_fLastRequest = GetGameTime();

    if (g_cvDebug.BoolValue)
        LogMessage("[HordeCounter] SpawnMob_Post +%d total=%d spawned=%d source=%d",
            amount, g_iAccepted, g_iSpawned, view_as<int>(g_Source));

    if (g_hTimer == null)
        g_hTimer = CreateTimer(1.0, Timer_CheckEnd, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnable.BoolValue || !g_bActive)
        return;

    if (!StrEqual(classname, "infected", false))
        return;

    g_iSpawned++;

    if (g_cvDebug.BoolValue)
        LogMessage("[HordeCounter] infected created entity=%d actual=%d", entity, g_iSpawned);
}

HordeSource DetectSource()
{
    if (g_fLastAlarmTime > 0.0 && (GetGameTime() - g_fLastAlarmTime) <= g_cvAlarmWindow.FloatValue)
        return HordeSource_AlarmCar;

    return HordeSource_Unknown;
}

void AnnounceStart(int amount)
{
    if (g_Source == HordeSource_AlarmCar)
    {
        int client = GetClientOfUserId(g_iLastAlarmUserId);
        if (client > 0 && IsClientInGame(client))
            PrintToChatAll("%t", "AlarmHordeStartPlayer", client, amount);
        else
            PrintToChatAll("%t", "AlarmHordeStart", amount);
    }
    else
    {
        PrintToChatAll("%t", "HordeStart", amount);
    }
}

public Action Timer_CheckEnd(Handle timer)
{
    if (!g_bActive)
    {
        g_hTimer = null;
        return Plugin_Stop;
    }

    if ((GetGameTime() - g_fLastRequest) < g_cvQuiet.FloatValue)
        return Plugin_Continue;

    if (g_cvEnd.BoolValue)
    {
        if (g_Source == HordeSource_AlarmCar)
            PrintToChatAll("%t", "AlarmHordeEnd", g_iAccepted, g_iSpawned);
        else
            PrintToChatAll("%t", "HordeEnd", g_iAccepted, g_iSpawned);
    }

    if (g_cvDebug.BoolValue)
        LogMessage("[HordeCounter] end accepted=%d actual=%d source=%d",
            g_iAccepted, g_iSpawned, view_as<int>(g_Source));

    g_hTimer = null;
    ClearHorde();
    return Plugin_Stop;
}

void ClearHorde()
{
    g_bActive = false;
    g_iAccepted = 0;
    g_iSpawned = 0;
    g_fLastRequest = 0.0;
    g_Source = HordeSource_Unknown;
}

void ResetAll()
{
    ClearHorde();
    g_fLastAlarmTime = 0.0;
    g_iLastAlarmUserId = 0;

    if (g_hTimer != null)
    {
        delete g_hTimer;
        g_hTimer = null;
    }
}
