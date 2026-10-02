#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <multicolors>

#define PLUGIN_NAME        "L4D2 Tank SI Stats"
#define PLUGIN_VERSION     "1.1.0"

#define TEAM_SURVIVOR      2
#define TEAM_INFECTED      3

#define ZC_SMOKER          1
#define ZC_BOOMER          2
#define ZC_HUNTER          3
#define ZC_SPITTER         4
#define ZC_JOCKEY          5
#define ZC_CHARGER         6
#define ZC_TANK            8

public Plugin myinfo =
{
    name = PLUGIN_NAME,
    author = "Ts. & UUZ",
    description = "统计Tank局期间其他特感玩家的伤害和特感使用次数",
    version = PLUGIN_VERSION,
    url = ""
};

bool g_bTankFight = false;

// 本次 Tank 战每名玩家造成的伤害
int g_iDamage[MAXPLAYERS + 1];

// 直接使用 m_zombieClass 作为下标：1~6 为六种普通特感
int g_iClassCount[MAXPLAYERS + 1][9];

// 本次 Tank 战中是否担任过 Tank。担任过 Tank 的玩家最终不显示。
bool g_bWasTank[MAXPLAYERS + 1];

// 是否产生过可显示的数据（伤害 > 0 或至少使用过一次普通特感）
bool g_bHasData[MAXPLAYERS + 1];

// 保存名字，方便玩家死亡、切换状态后仍能正常打印
char g_sPlayerName[MAXPLAYERS + 1][MAX_NAME_LENGTH];

// 用于抑制 player_spawn / bot_player_replace 在极短时间内对同一条生命的重复计数
float g_fLastClassCountTime[MAXPLAYERS + 1];
int g_iLastCountedClass[MAXPLAYERS + 1];

// 每名生还者当前身上的 Boomer 胆汁归属，保存 Boomer 的 userid
// 这个状态在 Tank 战之外也会追踪，这样 Tank 刚开始时若胆汁仍未结束，后续 CI 伤害仍可正确归属。
int g_iBileOwnerUserId[MAXPLAYERS + 1];

// 用于死亡爆炸的兜底归属
int g_iRecentExplodedBoomerUserId = 0;
float g_fRecentBoomerExplodeTime = -1000.0;

ConVar g_cvEnable;
ConVar g_cvShowSpitter;
ConVar g_cvSortAscending;

public void OnPluginStart()
{
    g_cvEnable = CreateConVar(
        "l4d2_tankstats_enable",
        "1",
        "是否启用 Tank 局特感统计。0=关闭，1=开启",
        FCVAR_NOTIFY,
        true, 0.0,
        true, 1.0
    );

    g_cvShowSpitter = CreateConVar(
        "l4d2_tankstats_show_spitter",
        "0",
        "是否在聊天结果中显示 Spitter/口水次数。0=不显示（与截图一致），1=显示",
        FCVAR_NOTIFY,
        true, 0.0,
        true, 1.0
    );

    g_cvSortAscending = CreateConVar(
        "l4d2_tankstats_sort_ascending",
        "1",
        "结果是否按伤害从低到高排序。0=高到低，1=低到高",
        FCVAR_NOTIFY,
        true, 0.0,
        true, 1.0
    );

    AutoExecConfig(true, "l4d2_tank_si_stats");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end", Event_RoundEnd, EventHookMode_PostNoCopy);

    HookEvent("tank_spawn", Event_TankSpawn, EventHookMode_Post);
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
    HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);

    HookEvent("bot_player_replace", Event_BotPlayerReplace, EventHookMode_Post);
    HookEvent("player_bot_replace", Event_PlayerBotReplace, EventHookMode_Post);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);

    HookEvent("player_now_it", Event_PlayerNowIt, EventHookMode_Post);
    HookEvent("player_no_longer_it", Event_PlayerNoLongerIt, EventHookMode_Post);
    HookEvent("boomer_exploded", Event_BoomerExploded, EventHookMode_Post);

    ResetEverything();

    // 支持插件中途加载：为已经在服务器里的客户端挂伤害 Hook。
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client))
        {
            SDKHook(client, SDKHook_OnTakeDamageAlive, OnTakeDamageAlive);
        }
    }

    CreateTimer(1.0, Timer_LateLoadCheck, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapStart()
{
    ResetEverything();
}

public void OnMapEnd()
{
    ResetEverything();
}

public void OnClientPutInServer(int client)
{
    ResetClientFightStats(client);
    g_iBileOwnerUserId[client] = 0;

    SDKHook(client, SDKHook_OnTakeDamageAlive, OnTakeDamageAlive);
}

public void OnClientDisconnect(int client)
{
    // client 作为生还者时，清掉他这个槽位上的胆汁状态。
    if (client > 0 && client <= MaxClients)
    {
        g_iBileOwnerUserId[client] = 0;
    }
}

// =========================================================
// 回合
// =========================================================

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    ResetEverything();
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
    {
        ResetEverything();
        return;
    }

    if (g_bTankFight)
    {
        EndTankFight();
    }
}

// =========================================================
// Tank 开始 / 出生
// =========================================================

public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
        return;

    int tank = GetClientOfUserId(event.GetInt("userid"));

    if (!IsValidClient(tank))
        return;

    if (!g_bTankFight)
    {
        StartTankFight(tank);
    }
    else
    {
        MarkAsTank(tank);
    }
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    RequestFrame(Frame_ProcessPlayerSpawn, userid);
}

public void Frame_ProcessPlayerSpawn(any data)
{
    if (!g_cvEnable.BoolValue)
        return;

    int client = GetClientOfUserId(data);

    if (!IsValidClient(client))
        return;

    if (GetClientTeam(client) != TEAM_INFECTED)
        return;

    int zombieClass = GetZombieClass(client);

    // player_spawn 有时会比 tank_spawn 更早，因此这里也作为 Tank 开始的兜底入口。
    if (zombieClass == ZC_TANK)
    {
        if (!g_bTankFight)
        {
            StartTankFight(client);
        }
        else
        {
            MarkAsTank(client);
        }
        return;
    }

    if (!g_bTankFight)
        return;

    if (IsFakeClient(client))
        return;

    if (!IsPlayerAlive(client))
        return;

    // Ghost 不算“已经使用了一次特感”，只统计真正实体化后的生命。
    if (IsInfectedGhost(client))
        return;

    if (g_bWasTank[client])
        return;

    CountSpecialUse(client, zombieClass);
}

// =========================================================
// 玩家接管 Bot / Bot 接管玩家
// =========================================================

public void Event_BotPlayerReplace(Event event, const char[] name, bool dontBroadcast)
{
    int playerUserId = event.GetInt("player");
    RequestFrame(Frame_ProcessBotTakeover, playerUserId);
}

public void Frame_ProcessBotTakeover(any data)
{
    if (!g_cvEnable.BoolValue)
        return;

    int client = GetClientOfUserId(data);

    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    if (GetClientTeam(client) != TEAM_INFECTED)
        return;

    int zombieClass = GetZombieClass(client);

    if (zombieClass == ZC_TANK)
    {
        if (!g_bTankFight)
        {
            StartTankFight(client);
        }
        else
        {
            MarkAsTank(client);
        }
        return;
    }

    if (!g_bTankFight)
        return;

    if (!IsPlayerAlive(client) || IsInfectedGhost(client))
        return;

    if (g_bWasTank[client])
        return;

    // 按当前需求：真人接管一个已经存在的普通特感 Bot，也视为使用该特感一次。
    CountSpecialUse(client, zombieClass);
}

public void Event_PlayerBotReplace(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue || !g_bTankFight)
        return;

    int player = GetClientOfUserId(event.GetInt("player"));

    if (!IsValidClient(player))
        return;

    RememberPlayerName(player);

    // 如果真人 Tank 被 Bot 接管，真人仍然属于本次 Tank 玩家，继续排除。
    if (GetClientTeam(player) == TEAM_INFECTED && GetZombieClass(player) == ZC_TANK)
    {
        MarkAsTank(player);
    }
}

// =========================================================
// 普通可玩特感对生还者造成的伤害
// =========================================================

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue || !g_bTankFight)
        return;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (!IsValidClient(victim))
        return;

    if (GetClientTeam(victim) != TEAM_SURVIVOR)
        return;

    // 这里仅统计“可玩感染者玩家”造成的伤害。
    // 普通感染者 CI 的伤害在 OnTakeDamageAlive 中单独归给 Boomer，避免重复。
    if (!IsValidClient(attacker))
        return;

    if (GetClientTeam(attacker) != TEAM_INFECTED)
        return;

    if (IsFakeClient(attacker))
        return;

    if (g_bWasTank[attacker])
        return;

    if (GetZombieClass(attacker) == ZC_TANK)
        return;

    int damage = event.GetInt("dmg_health");

    if (damage <= 0)
        return;

    AddDamage(attacker, damage);
}

// =========================================================
// Boomer 胆汁归属
// =========================================================

public void Event_BoomerExploded(Event event, const char[] name, bool dontBroadcast)
{
    int boomer = GetClientOfUserId(event.GetInt("userid"));

    if (!IsHumanBoomer(boomer))
        return;

    g_iRecentExplodedBoomerUserId = GetClientUserId(boomer);
    g_fRecentBoomerExplodeTime = GetGameTime();

    RememberPlayerName(boomer);
}

public void Event_PlayerNowIt(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));

    if (!IsValidClient(victim))
        return;

    if (GetClientTeam(victim) != TEAM_SURVIVOR)
        return;

    // L4D2 中 by_boomer=true 代表此次胆汁确实来自 Boomer，而不是胆汁瓶等其它来源。
    if (!event.GetBool("by_boomer"))
        return;

    int attackerUserId = event.GetInt("attacker");
    int boomer = GetClientOfUserId(attackerUserId);

    if (!IsHumanBoomer(boomer))
    {
        // 死亡爆炸时做一个短时间兜底。
        if (event.GetBool("exploded")
            && (GetGameTime() - g_fRecentBoomerExplodeTime) <= 0.50)
        {
            int fallback = GetClientOfUserId(g_iRecentExplodedBoomerUserId);

            if (IsHumanBoomer(fallback))
            {
                boomer = fallback;
                attackerUserId = g_iRecentExplodedBoomerUserId;
            }
        }
    }

    if (!IsHumanBoomer(boomer))
        return;

    // 这里只建立“胆汁属于谁”的关系，不要求当前正处于 Tank 战。
    // 这样如果 Tank 出现前几秒已经被喷中，Tank 出现后 CI 继续打人时仍能正确归属。
    g_iBileOwnerUserId[victim] = attackerUserId;

    RememberPlayerName(boomer);
}

public void Event_PlayerNoLongerIt(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));

    if (victim <= 0 || victim > MaxClients)
        return;

    g_iBileOwnerUserId[victim] = 0;
}

// =========================================================
// 普通感染者伤害 -> 归属给让该生还者中胆汁的 Boomer
// =========================================================

public Action OnTakeDamageAlive(
    int victim,
    int &attacker,
    int &inflictor,
    float &damage,
    int &damagetype
)
{
    if (!g_cvEnable.BoolValue || !g_bTankFight)
        return Plugin_Continue;

    if (!IsValidClient(victim))
        return Plugin_Continue;

    if (GetClientTeam(victim) != TEAM_SURVIVOR)
        return Plugin_Continue;

    if (damage <= 0.0)
        return Plugin_Continue;

    // 玩家攻击者（Tank/SI/Survivor）不走这里，避免和 player_hurt 重复。
    if (attacker >= 1 && attacker <= MaxClients)
        return Plugin_Continue;

    if (!IsCommonInfectedEntity(attacker))
        return Plugin_Continue;

    int ownerUserId = g_iBileOwnerUserId[victim];

    if (ownerUserId <= 0)
        return Plugin_Continue;

    int boomer = GetClientOfUserId(ownerUserId);

    // 归属建立时已经确认过他是 Boomer；此时即使 Boomer 已死，也继续把胆汁期间 CI 伤害算给他。
    if (!CanCreditHumanPlayer(boomer))
        return Plugin_Continue;

    int actualDamage = RoundToNearest(damage);

    if (actualDamage <= 0)
        return Plugin_Continue;

    AddDamage(boomer, actualDamage);

    return Plugin_Continue;
}

// =========================================================
// 坦克局结束判断
// =========================================================

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));

    // 生还者死亡后清除该槽位的胆汁归属。
    if (IsValidClient(victim) && GetClientTeam(victim) == TEAM_SURVIVOR)
    {
        g_iBileOwnerUserId[victim] = 0;
    }

    if (!g_cvEnable.BoolValue || !g_bTankFight)
        return;

    bool tankDied = false;

    if (IsValidClient(victim)
        && GetClientTeam(victim) == TEAM_INFECTED
        && GetZombieClass(victim) == ZC_TANK)
    {
        tankDied = true;
    }
    else
    {
        char victimName[32];
        event.GetString("victimname", victimName, sizeof(victimName));

        if (StrEqual(victimName, "Tank", false))
        {
            tankDied = true;
        }
    }

    if (tankDied)
    {
        // 延迟检查以兼容 Tank 控制权切换和多 Tank 情况。
        CreateTimer(1.1, Timer_CheckTankEnd, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bTankFight)
        return;

    int client = GetClientOfUserId(event.GetInt("userid"));

    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
        return;

    RememberPlayerName(client);

    if (GetClientTeam(client) == TEAM_INFECTED && GetZombieClass(client) == ZC_TANK)
    {
        CreateTimer(1.0, Timer_CheckTankEnd, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_CheckTankEnd(Handle timer)
{
    if (!g_bTankFight)
        return Plugin_Stop;

    if (!AnyTankAlive())
    {
        EndTankFight();
    }

    return Plugin_Stop;
}

// =========================================================
// Tank 局开始 / 结束
// =========================================================

void StartTankFight(int tankClient)
{
    ClearFightStats();
    g_bTankFight = true;

    MarkAsTank(tankClient);

    // Tank 出现时场上已经实体化的普通特感，也算本次 Tank 战使用过一次该职业。
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidClient(client))
            continue;

        if (GetClientTeam(client) != TEAM_INFECTED)
            continue;

        if (!IsPlayerAlive(client))
            continue;

        int zombieClass = GetZombieClass(client);

        if (zombieClass == ZC_TANK)
        {
            MarkAsTank(client);
            continue;
        }

        if (IsFakeClient(client))
            continue;

        if (IsInfectedGhost(client))
            continue;

        if (g_bWasTank[client])
            continue;

        CountSpecialUse(client, zombieClass);
    }
}

void EndTankFight()
{
    if (!g_bTankFight)
        return;

    g_bTankFight = false;
    PrintTankStats();
}

// =========================================================
// 结果输出
// =========================================================

void PrintTankStats()
{
    PrintToChatAll("\x04[!]\x01 Tank局特感造成伤害列表:");

    int order[MAXPLAYERS + 1];
    int count = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_bWasTank[client])
            continue;

        if (!g_bHasData[client])
            continue;

        order[count++] = client;
    }

    if (count == 0)
    {
        PrintToChatAll("\x01本次 Tank 局没有可显示的非 Tank 特感数据。");
        return;
    }

    // 简单插入排序。默认与截图一样按伤害从低到高。
    for (int i = 1; i < count; i++)
    {
        int key = order[i];
        int j = i - 1;

        while (j >= 0 && ShouldMoveBefore(key, order[j]))
        {
            order[j + 1] = order[j];
            j--;
        }

        order[j + 1] = key;
    }

    for (int i = 0; i < count; i++)
    {
        int client = order[i];

        char playerName[MAX_NAME_LENGTH];

        if (g_sPlayerName[client][0] != '\0')
        {
            strcopy(playerName, sizeof(playerName), g_sPlayerName[client]);
        }
        else if (IsValidClient(client))
        {
            GetClientName(client, playerName, sizeof(playerName));
        }
        else
        {
            Format(playerName, sizeof(playerName), "玩家#%d", client);
        }

        if (!g_cvShowSpitter.BoolValue)
        {
            PrintToChatAll(
                "\x03%s\x01: \x04%d伤害\x01 [猎人:\x03%d\x01 牛:\x03%d\x01 舌头:\x03%d\x01 猴子:\x03%d\x01 胖子:\x03%d\x01]",
                playerName,
                g_iDamage[client],
                g_iClassCount[client][ZC_HUNTER],
                g_iClassCount[client][ZC_CHARGER],
                g_iClassCount[client][ZC_SMOKER],
                g_iClassCount[client][ZC_JOCKEY],
                g_iClassCount[client][ZC_BOOMER]
            );
        }
        else
        {
            PrintToChatAll(
                "\x03%s\x01: \x04%d伤害\x01 [猎人:\x03%d\x01 牛:\x03%d\x01 舌头:\x03%d\x01 猴子:\x03%d\x01 胖子:\x03%d\x01 口水:\x03%d\x01]",
                playerName,
                g_iDamage[client],
                g_iClassCount[client][ZC_HUNTER],
                g_iClassCount[client][ZC_CHARGER],
                g_iClassCount[client][ZC_SMOKER],
                g_iClassCount[client][ZC_JOCKEY],
                g_iClassCount[client][ZC_BOOMER],
                g_iClassCount[client][ZC_SPITTER]
            );
        }
    }
}

bool ShouldMoveBefore(int a, int b)
{
    if (g_cvSortAscending.BoolValue)
    {
        if (g_iDamage[a] != g_iDamage[b])
            return g_iDamage[a] < g_iDamage[b];
    }
    else
    {
        if (g_iDamage[a] != g_iDamage[b])
            return g_iDamage[a] > g_iDamage[b];
    }

    // 同伤害时按 client index 稳定排序
    return a < b;
}

// =========================================================
// 计数 / 伤害辅助
// =========================================================

void CountSpecialUse(int client, int zombieClass)
{
    if (!IsCountableSpecial(zombieClass))
        return;

    float now = GetGameTime();

    // spawn 与 takeover 在同一条生命上可能紧挨着触发，做一个短时间去重。
    if (g_iLastCountedClass[client] == zombieClass
        && (now - g_fLastClassCountTime[client]) < 0.50)
    {
        return;
    }

    g_iLastCountedClass[client] = zombieClass;
    g_fLastClassCountTime[client] = now;

    g_iClassCount[client][zombieClass]++;
    g_bHasData[client] = true;

    RememberPlayerName(client);
}

void AddDamage(int client, int damage)
{
    if (damage <= 0)
        return;

    if (client <= 0 || client > MaxClients)
        return;

    if (g_bWasTank[client])
        return;

    g_iDamage[client] += damage;
    g_bHasData[client] = true;

    RememberPlayerName(client);
}

void MarkAsTank(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    g_bWasTank[client] = true;
    RememberPlayerName(client);
}

// =========================================================
// Tank 查找 / 插件中途加载
// =========================================================

public Action Timer_LateLoadCheck(Handle timer)
{
    if (!g_cvEnable.BoolValue || g_bTankFight)
        return Plugin_Stop;

    int tank = FindAliveTank();

    if (tank > 0)
    {
        StartTankFight(tank);
    }

    return Plugin_Stop;
}

bool AnyTankAlive()
{
    return FindAliveTank() > 0;
}

int FindAliveTank()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidClient(client))
            continue;

        if (GetClientTeam(client) != TEAM_INFECTED)
            continue;

        if (!IsPlayerAlive(client))
            continue;

        if (GetZombieClass(client) == ZC_TANK)
        {
            return client;
        }
    }

    return 0;
}

// =========================================================
// 判断辅助
// =========================================================

bool IsValidClient(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client);
}

bool CanCreditHumanPlayer(int client)
{
    return IsValidClient(client)
        && !IsFakeClient(client)
        && !g_bWasTank[client];
}

bool IsHumanBoomer(int client)
{
    if (!IsValidClient(client))
        return false;

    if (IsFakeClient(client))
        return false;

    if (GetClientTeam(client) != TEAM_INFECTED)
        return false;

    if (GetZombieClass(client) != ZC_BOOMER)
        return false;

    return true;
}

bool IsCommonInfectedEntity(int entity)
{
    if (entity <= MaxClients || !IsValidEntity(entity))
        return false;

    char classname[32];
    GetEntityClassname(entity, classname, sizeof(classname));

    return StrEqual(classname, "infected", false);
}

bool IsCountableSpecial(int zombieClass)
{
    switch (zombieClass)
    {
        case ZC_SMOKER,
             ZC_BOOMER,
             ZC_HUNTER,
             ZC_SPITTER,
             ZC_JOCKEY,
             ZC_CHARGER:
        {
            return true;
        }
    }

    return false;
}

bool IsInfectedGhost(int client)
{
    if (!IsValidClient(client))
        return false;

    return GetEntProp(client, Prop_Send, "m_isGhost") != 0;
}

int GetZombieClass(int client)
{
    if (!IsValidClient(client))
        return 0;

    return GetEntProp(client, Prop_Send, "m_zombieClass");
}

void RememberPlayerName(int client)
{
    if (!IsValidClient(client))
        return;

    GetClientName(client, g_sPlayerName[client], sizeof(g_sPlayerName[]));
}

// =========================================================
// 重置
// =========================================================

void ResetClientFightStats(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    g_iDamage[client] = 0;

    for (int zombieClass = 0; zombieClass < 9; zombieClass++)
    {
        g_iClassCount[client][zombieClass] = 0;
    }

    g_bWasTank[client] = false;
    g_bHasData[client] = false;

    g_sPlayerName[client][0] = '\0';

    g_fLastClassCountTime[client] = -1000.0;
    g_iLastCountedClass[client] = 0;
}

void ClearFightStats()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        ResetClientFightStats(client);
    }
}

void ResetBileTracking()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        g_iBileOwnerUserId[client] = 0;
    }

    g_iRecentExplodedBoomerUserId = 0;
    g_fRecentBoomerExplodeTime = -1000.0;
}

void ResetEverything()
{
    g_bTankFight = false;
    ClearFightStats();
    ResetBileTracking();
}
