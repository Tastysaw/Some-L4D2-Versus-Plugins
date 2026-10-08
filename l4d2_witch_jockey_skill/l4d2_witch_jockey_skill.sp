#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <multicolors>

#define PLUGIN_VERSION "2.0.0"

#define TEAM_SURVIVOR 2
#define TEAM_INFECTED 3
#define ZC_JOCKEY 5

#define SHOTGUN_BLAST_TIME 0.10
#define WITCH_CHECK_TIME   0.10
#define SHOVE_TIME         0.05
#define DMGARRAYEXT        7

enum WitchData
{
    WTCH_NONE = 0,
    WTCH_HEALTH,
    WTCH_GOTSLASH,
    WTCH_STARTLED,
    WTCH_CROWNER,
    WTCH_CROWNSHOT,
    WTCH_CROWNTYPE
};

StringMap g_WitchTrie;
ConVar g_cvWitchHealth;
ConVar g_cvDrawCrownDamage;

float g_fWitchShotStart[MAXPLAYERS + 1];
float g_fVictimLastShove[MAXPLAYERS + 1][MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "L4D2 Witch Crown + Jockey Air Shove Notify",
    author = "Ts UUZ",
    description = "Reports Witch crown/draw-crown kills and airborne Jockey shove-stops.",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_WitchTrie = new StringMap();

    g_cvWitchHealth = FindConVar("z_witch_health");
    g_cvDrawCrownDamage = CreateConVar(
        "sm_witch_drawcrown_damage",
        "500",
        "Minimum final shotgun-blast damage required to count as draw-crown (引秒).",
        FCVAR_NOTIFY,
        true,
        1.0
    );

    HookEvent("witch_spawn", Event_WitchSpawned, EventHookMode_Post);
    HookEvent("witch_killed", Event_WitchKilled, EventHookMode_Post);
    HookEvent("witch_harasser_set", Event_WitchHarasserSet, EventHookMode_Post);
    HookEvent("player_shoved", Event_PlayerShoved, EventHookMode_Post);
    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamageByWitch);
        }
    }
}

public void OnMapStart()
{
    ResetAllState();
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamageByWitch);
}

public void OnClientDisconnect(int client)
{
    SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamageByWitch);

    g_fWitchShotStart[client] = 0.0;

    for (int i = 1; i <= MaxClients; i++)
    {
        g_fVictimLastShove[client][i] = 0.0;
        g_fVictimLastShove[i][client] = 0.0;
    }
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    ResetAllState();
}

public void Event_WitchSpawned(Event event, const char[] name, bool dontBroadcast)
{
    int witch = event.GetInt("witchid");

    if (!IsValidEntity(witch))
    {
        return;
    }

    SDKHook(witch, SDKHook_OnTakeDamagePost, OnTakeDamagePost_Witch);

    int data[MAXPLAYERS + DMGARRAYEXT] = {0};
    data[MAXPLAYERS + view_as<int>(WTCH_HEALTH)] = GetWitchHealth();

    char key[16];
    IntToString(witch, key, sizeof(key));
    g_WitchTrie.SetArray(key, data, sizeof(data));
}

public Action Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
    int witch = event.GetInt("witchid");
    int attacker = GetClientOfUserId(event.GetInt("userid"));
    bool oneShot = event.GetBool("oneshot");

    if (IsValidEntity(witch))
    {
        SDKUnhook(witch, SDKHook_OnTakeDamagePost, OnTakeDamagePost_Witch);
    }

    if (!IsValidSurvivor(attacker))
    {
        RemoveWitchEntry(witch);
        return Plugin_Continue;
    }

    DataPack pack = new DataPack();
    pack.WriteCell(attacker);
    pack.WriteCell(witch);
    pack.WriteCell(oneShot ? 1 : 0);

    CreateTimer(WITCH_CHECK_TIME, Timer_CheckWitchCrown, pack, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

public void Event_WitchHarasserSet(Event event, const char[] name, bool dontBroadcast)
{
    int witch = event.GetInt("witchid");

    if (witch <= 0)
    {
        return;
    }

    char key[16];
    IntToString(witch, key, sizeof(key));

    int data[MAXPLAYERS + DMGARRAYEXT] = {0};

    if (!g_WitchTrie.GetArray(key, data, sizeof(data)))
    {
        data[MAXPLAYERS + view_as<int>(WTCH_HEALTH)] = GetWitchHealth();
    }

    data[MAXPLAYERS + view_as<int>(WTCH_STARTLED)] = 1;
    g_WitchTrie.SetArray(key, data, sizeof(data));
}

public Action OnTakeDamageByWitch(
    int victim,
    int &attacker,
    int &inflictor,
    float &damage,
    int &damagetype
)
{
    if (!IsValidSurvivor(victim) || damage <= 0.0 || !IsWitch(attacker))
    {
        return Plugin_Continue;
    }

    char key[16];
    IntToString(attacker, key, sizeof(key));

    int data[MAXPLAYERS + DMGARRAYEXT] = {0};

    if (!g_WitchTrie.GetArray(key, data, sizeof(data)))
    {
        data[MAXPLAYERS + view_as<int>(WTCH_HEALTH)] = GetWitchHealth();
    }

    // Witch has already hit a survivor: no longer a clean crown.
    data[MAXPLAYERS + view_as<int>(WTCH_GOTSLASH)] = 1;
    g_WitchTrie.SetArray(key, data, sizeof(data));

    return Plugin_Continue;
}

public void OnTakeDamagePost_Witch(
    int victim,
    int attacker,
    int inflictor,
    float damage,
    int damagetype
)
{
    char key[16];
    IntToString(victim, key, sizeof(key));

    int data[MAXPLAYERS + DMGARRAYEXT] = {0};

    if (!g_WitchTrie.GetArray(key, data, sizeof(data)))
    {
        data[MAXPLAYERS + view_as<int>(WTCH_HEALTH)] = GetWitchHealth();
    }

    if (IsValidSurvivor(attacker))
    {
        int iDamage = RoundToFloor(damage);

        data[attacker] += iDamage;
        data[MAXPLAYERS + view_as<int>(WTCH_HEALTH)] -= iDamage;

        // Damage pellets within 0.1s are treated as one shotgun blast,
        // matching the reference skill-detect implementation.
        if (g_fWitchShotStart[attacker] == 0.0
            || (GetGameTime() - g_fWitchShotStart[attacker]) > SHOTGUN_BLAST_TIME)
        {
            g_fWitchShotStart[attacker] = GetGameTime();

            data[MAXPLAYERS + view_as<int>(WTCH_CROWNER)] = attacker;
            data[MAXPLAYERS + view_as<int>(WTCH_CROWNSHOT)] = 0;
            data[MAXPLAYERS + view_as<int>(WTCH_CROWNTYPE)] = (damagetype & DMG_BUCKSHOT) ? 1 : 0;
        }

        data[MAXPLAYERS + view_as<int>(WTCH_CROWNSHOT)] += iDamage;
    }
    else
    {
        // Non-survivor / environmental chip damage.
        data[0] += RoundToFloor(damage);
    }

    g_WitchTrie.SetArray(key, data, sizeof(data));
}

public Action Timer_CheckWitchCrown(Handle timer, DataPack pack)
{
    pack.Reset();

    int attacker = pack.ReadCell();
    int witch = pack.ReadCell();
    bool oneShot = view_as<bool>(pack.ReadCell());

    CheckWitchCrown(witch, attacker, oneShot);
    delete pack;

    return Plugin_Stop;
}

void CheckWitchCrown(int witch, int attacker, bool oneShot)
{
    char key[16];
    IntToString(witch, key, sizeof(key));

    int data[MAXPLAYERS + DMGARRAYEXT] = {0};

    if (!g_WitchTrie.GetArray(key, data, sizeof(data)))
    {
        return;
    }

    int witchHealth = GetWitchHealth();

    // The event's "oneshot" flag is used as a safeguard, just like the
    // reference implementation, because shotgun damage callbacks can be late.
    if (oneShot)
    {
        data[MAXPLAYERS + view_as<int>(WTCH_CROWNTYPE)] = 1;
    }

    // If Witch already hit someone, or the killing blast was not recognized
    // as buckshot, do not report crown/draw-crown.
    if (data[MAXPLAYERS + view_as<int>(WTCH_GOTSLASH)]
        || !data[MAXPLAYERS + view_as<int>(WTCH_CROWNTYPE)])
    {
        RemoveWitchEntry(witch);
        return;
    }

    int crownShot = data[MAXPLAYERS + view_as<int>(WTCH_CROWNSHOT)];
    int chipDamage = 0;

    // Clean crown / 秒杀:
    // Witch was not startled before the kill, and the final shotgun blast
    // was enough to kill a full-health Witch (or the event says oneshot).
    if (!data[MAXPLAYERS + view_as<int>(WTCH_STARTLED)]
        && (oneShot || crownShot >= witchHealth))
    {
        for (int i = 0; i <= MaxClients; i++)
        {
            if (i == attacker)
            {
                continue;
            }

            chipDamage += data[i];
        }

        int realDamage = witchHealth - chipDamage;
        if (realDamage < 1)
        {
            realDamage = crownShot;
        }

        CPrintToChatAll(
            "{green}★★{olive} %N {red}秒杀了{default} Witch {olive}[伤害 %d]",
            attacker,
            realDamage
        );

        RemoveWitchEntry(witch);
        return;
    }

    // Draw crown / 引秒:
    // Witch was already startled/chipped, but the final shotgun blast
    // still reached the configured draw-crown threshold.
    int drawThreshold = g_cvDrawCrownDamage.IntValue;

    if (crownShot >= drawThreshold)
    {
        for (int i = 0; i <= MaxClients; i++)
        {
            if (i == attacker)
            {
                chipDamage += data[i] - crownShot;
            }
            else
            {
                chipDamage += data[i];
            }
        }

        if (chipDamage < 0)
        {
            chipDamage = 0;
        }

        int realFinalShot = witchHealth - chipDamage;

        if (realFinalShot < 1)
        {
            realFinalShot = 1;
        }

        // Preserve the reference plugin's re-check after removing fake/overkill damage.
        if (realFinalShot >= drawThreshold)
        {
            CPrintToChatAll(
                "{green}★★★{olive} %N {red}引秒了{default} Witch {olive}[击杀伤害:%d / 初始伤害:%d]",
                attacker,
                realFinalShot,
                chipDamage
            );
        }
    }

    RemoveWitchEntry(witch);
}

public Action Event_PlayerShoved(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (!IsValidSurvivor(attacker) || !IsValidInfected(victim))
    {
        return Plugin_Continue;
    }

    if (GetEntProp(victim, Prop_Send, "m_zombieClass") != ZC_JOCKEY)
    {
        return Plugin_Continue;
    }

    float now = GetGameTime();

    if (g_fVictimLastShove[victim][attacker] != 0.0
        && (now - g_fVictimLastShove[victim][attacker]) < SHOVE_TIME)
    {
        return Plugin_Continue;
    }

    g_fVictimLastShove[victim][attacker] = now;

    if (!IsJockeyLeaping(victim))
    {
        return Plugin_Continue;
    }

    CPrintToChatAll(
        "{green}★★{olive} %N {blue}推停了空中的 {olive}%N (Jockey)",
        attacker,
        victim
    );

    return Plugin_Continue;
}

bool IsJockeyLeaping(int jockey)
{
    if (!IsValidInfected(jockey))
    {
        return false;
    }

    if (GetEntProp(jockey, Prop_Send, "m_zombieClass") != ZC_JOCKEY
        || GetEntPropEnt(jockey, Prop_Send, "m_hGroundEntity") > -1
        || GetEntityMoveType(jockey) != MOVETYPE_WALK
        || GetEntProp(jockey, Prop_Send, "m_nWaterLevel") >= 3
        || GetEntPropEnt(jockey, Prop_Send, "m_jockeyVictim") > -1)
    {
        return false;
    }

    int ability = GetEntPropEnt(jockey, Prop_Send, "m_customAbility");

    if (IsValidEntity(ability)
        && HasEntProp(ability, Prop_Send, "m_isLeaping")
        && GetEntProp(ability, Prop_Send, "m_isLeaping"))
    {
        return true;
    }

    float velocity[3];
    GetEntPropVector(jockey, Prop_Data, "m_vecVelocity", velocity);
    velocity[2] = 0.0;

    return GetVectorLength(velocity) >= 15.0
        && GetEntPropEnt(jockey, Prop_Send, "m_hGroundEntity") == -1;
}

bool IsWitch(int entity)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
    {
        return false;
    }

    char classname[32];
    GetEntityClassname(entity, classname, sizeof(classname));
    return StrEqual(classname, "witch");
}

bool IsValidSurvivor(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && GetClientTeam(client) == TEAM_SURVIVOR;
}

bool IsValidInfected(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && GetClientTeam(client) == TEAM_INFECTED;
}

int GetWitchHealth()
{
    if (g_cvWitchHealth != null)
    {
        return g_cvWitchHealth.IntValue;
    }

    return 1000;
}

void RemoveWitchEntry(int witch)
{
    char key[16];
    IntToString(witch, key, sizeof(key));
    g_WitchTrie.Remove(key);
}

void ResetAllState()
{
    g_WitchTrie.Clear();

    for (int i = 1; i <= MaxClients; i++)
    {
        g_fWitchShotStart[i] = 0.0;

        for (int j = 1; j <= MaxClients; j++)
        {
            g_fVictimLastShove[i][j] = 0.0;
        }
    }
}
