#pragma semicolon 1
#pragma newdecls required

#include <colors>
#include <readyup>
#include <sourcemod>
#include <left4dhooks>

#define TEAM_SPECTATOR          1
#define TEAM_INFECTED           3
#define ZOMBIECLASS_TANK        8
#define IS_SPECTATOR(%1)        (GetClientTeam(%1) == TEAM_SPECTATOR)
#define IS_INFECTED(%1)         (GetClientTeam(%1) == TEAM_INFECTED)
#define IS_VALID_INFECTED(%1)   (IsClientInGame(%1) && IS_INFECTED(%1))
#define IS_VALID_SPECTATOR(%1)  (IsClientInGame(%1) && IS_SPECTATOR(%1))

ArrayList h_whosHadTank;
ArrayList h_tankQueue;

ConVar 
    hTankPrint,
    hTankWindow, 
    hTankDebug;

GlobalForward
    hForwardOnTryOfferingTankBot,
    hForwardOnTankSelection;

char 
    queuedTankSteamId[64],
    tankInitiallyChosen[64];

float 
    fTankGrace,
    initialTankLeft,
    gotTankAt;

int dcedTankFrustration = -1;

#define TANK_SWAP_SECONDS 20
int gSwapOwner[MAXPLAYERS + 1];
int gSwapToken[MAXPLAYERS + 1];
int gSwapFromUserId[MAXPLAYERS + 1];
int gSwapToUserId[MAXPLAYERS + 1];
int gSwapFromIndex[MAXPLAYERS + 1];
int gSwapToIndex[MAXPLAYERS + 1];
float gSwapDeadline[MAXPLAYERS + 1];
char gSwapFromAuth[MAXPLAYERS + 1][64];
char gSwapToAuth[MAXPLAYERS + 1][64];
int gSwapSerial;
int gSwapRoundSerial;
bool gSwapResetDone = true;
bool gSwapLive;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("GetTankSelection", Native_GetTankSelection);

    hForwardOnTryOfferingTankBot = new GlobalForward("TankControl_OnTryOfferingTankBot", ET_Ignore, Param_String);
    hForwardOnTankSelection = new GlobalForward("TankControl_OnTankSelection", ET_Ignore, Param_String);

    return APLRes_Success;
}

int Native_GetTankSelection(Handle plugin, int numParams) { return getInfectedPlayerBySteamId(queuedTankSteamId); }

public Plugin myinfo = 
{
    name = "L4D2 Tank Control",
    author = "arti, (Contributions by: Sheo, Sir, Altair-Sossai),Ts & UUZ修改",
    description = "Distributes the role of the tank evenly throughout the team, allows for overrides. (Includes forwards)",
    version = "0.0.30",
    url = "https://github.com/SirPlease/L4D2-Competitive-Rework"
}

public void OnPluginStart()
{
    LoadTranslation("l4d_tank_control_eq.phrases");
    LoadTranslation("l4d_tanklist.phrases");
    LoadTranslations("common.phrases");
    
    // Event hooks
    HookEvent("player_left_start_area", PlayerLeftStartArea_Event, EventHookMode_PostNoCopy);
    HookEvent("round_start", RoundStart_Event, EventHookMode_PostNoCopy);
    HookEvent("round_end", RoundEnd_Event, EventHookMode_PostNoCopy);
    HookEvent("player_team", PlayerTeam_Event, EventHookMode_Post);
    HookEvent("player_death", PlayerDeath_Event, EventHookMode_Post);
    
    // Initialise the tank arrays/data values
    h_whosHadTank = new ArrayList(ByteCountToCells(64));
    h_tankQueue = new ArrayList(ByteCountToCells(64));

    // Admin commands
    RegAdminCmd("sm_tankshuffle", TankShuffle_Cmd, ADMFLAG_SLAY, "Re-picks at random someone to become tank.");
    RegAdminCmd("sm_givetank", GiveTank_Cmd, ADMFLAG_SLAY, "Gives the tank to a selected player");

    // Register the boss commands
    RegConsoleCmd("sm_tank", Tank_Cmd, "Shows who is becoming the tank.");
    RegConsoleCmd("sm_boss", Tank_Cmd, "Shows who is becoming the tank.");
    RegConsoleCmd("sm_witch", Tank_Cmd, "Shows who is becoming the tank.");
    RegConsoleCmd("sm_tanklist", TankList_Cmd, "Privately shows the actual Tank allocation queue.");
    
    RegConsoleCmd("sm_swaptank", TankSwap_Cmd, "Request a consensual Tank queue swap during ready-up.");

    // Cvars
    hTankPrint  = CreateConVar("tankcontrol_print_all", "0", "Who gets to see who will become the tank? (0 = Infected, 1 = Everyone)");
    hTankWindow = CreateConVar("tankcontrol_force_window", "0.0", "Give player that was initially going to be Tank (or was Tank and dced) back the Tank this long after Tank was given to somebody else (0 = Off)");
    hTankDebug  = CreateConVar("tankcontrol_debug", "0", "Whether or not to debug to console");
}


/*=========================================================================
|                            Left4Dhooks                                  |
=========================================================================*/


public void L4D2_OnTankPassControl(int iOldTank, int iNewTank, int iPassCount)
{
    /*
    * As the Player switches to AI on disconnect/team switch, we have to make sure we're only checking this if the old Tank was AI.
    * Then apply the previous' Tank's Frustration and Grace Period (if it still had Grace)
    * We'll also be keeping the same Tank pass, which resolves Tanks that dc on 1st pass resulting into the Tank instantly going to 2nd pass.
    */
    if (dcedTankFrustration != -1 && IsFakeClient(iOldTank))
    {
        SetTankFrustration(iNewTank, dcedTankFrustration);
        CTimer_Start(GetFrustrationTimer(iNewTank), fTankGrace);
        L4D2Direct_SetTankPassedCount(L4D2Direct_GetTankPassedCount() - 1);
    }

    gotTankAt = GetGameTime();
    if (hTankDebug.BoolValue)
        PrintToConsoleAll("[TC] gotTankAt set to %f (iOldTank: %N - iNewTank: %N)", GetGameTime(), iOldTank, iNewTank);
}

/**
 * Make sure we give the tank to our queued player.
 */
public Action L4D_OnTryOfferingTankBot(int tank_index, bool &enterStatis)
{
    // Reset the tank's frustration if need be
    if (!IsFakeClient(tank_index)) 
    {
        PrintHintText(tank_index, "%t", "HintText");
        for (int i = 1; i <= MaxClients; i++) 
        {
            if (!IS_VALID_INFECTED(i) && !IS_VALID_SPECTATOR(i))
                continue;

            if (tank_index == i) 
                CPrintToChat(i, "%t %t", "TagRage", "RefilledBot");
            else 
                CPrintToChat(i, "%t %t", "TagRage", "Refilled", tank_index);
        }
        
        SetTankFrustration(tank_index, 100);
        L4D2Direct_SetTankPassedCount(L4D2Direct_GetTankPassedCount() + 1);

        return Plugin_Handled;
    }

    // Allow third party plugins to override tank selection
    char sOverrideTank[64];
    sOverrideTank[0] = '\0';
    Call_StartForward(hForwardOnTryOfferingTankBot);
    Call_PushStringEx(sOverrideTank, sizeof(sOverrideTank), SM_PARAM_STRING_UTF8, SM_PARAM_COPYBACK);
    Call_Finish();

    if (!StrEqual(sOverrideTank, ""))
        strcopy(queuedTankSteamId, sizeof(queuedTankSteamId), sOverrideTank);
    
    // If we don't have a queued tank, choose one
    if (StrEqual(queuedTankSteamId, ""))
        chooseTank(0);
    
    TankSwap_CancelAll();

    // Mark the player as having had tank
    if (!StrEqual(queuedTankSteamId, ""))
    {
        setTankTickets(queuedTankSteamId, 20000);

        if (h_whosHadTank.FindString(queuedTankSteamId) == -1)
            h_whosHadTank.PushString(queuedTankSteamId);

        int index = h_tankQueue.FindString(queuedTankSteamId);
        if (index != -1)
            h_tankQueue.Erase(index);
    }
    
    return Plugin_Continue;
}

public void L4D_OnLeaveStasis(int tank)
{
    // Tank is always AI here, delay by a frame.
    RequestFrame(L4D_OnLeaveStasis_Post, GetClientUserId(tank));
}

void L4D_OnLeaveStasis_Post(int userid)
{
    int tank = GetClientOfUserId(userid);
    // Tank passed from AI to a player, nothing to do here.
    if (!tank || !IsClientInGame(tank))
        return;
    
    // @Forgetest: 
    //   AI Tank may have committed suicide at the moment
    if (!IsPlayerAlive(tank) || GetEntProp(tank, Prop_Send, "m_isIncapacitated")) // Thanks to @sheo for noting the tank incap
        return;

    if (hTankDebug.BoolValue)
        PrintToConsoleAll("[TC] Tank was not properly assigned to a player, trying to re-assign...");

    int newTank = getInfectedPlayerBySteamId(queuedTankSteamId);

    // Still no candidates, give up.
    if (newTank == -1)
    {
        if (hTankDebug.BoolValue)
            PrintToConsoleAll("[TC] Tried to assign Tank to another player, but there's no one available?");

        return;
    }

    if (hTankDebug.BoolValue)
        PrintToConsoleAll("[TC] Assigned tank to %N.", newTank);

    L4D_ReplaceTank(tank, newTank);
    L4D2Direct_SetTankPassedCount(1); // Otherwise the Tank gets 3 controls.
}

/*=========================================================================
|                                 Events                                  |
=========================================================================*/


/**
 * When a new game starts, reset the tank pool.
 */
void RoundStart_Event(Event hEvent, const char[] eName, bool dontBroadcast)
{
    TankSwap_CancelAll();
    gSwapLive = false;
    gSwapResetDone = false;
    gSwapRoundSerial++;
    CreateTimer(10.0, newGame, gSwapRoundSerial, TIMER_FLAG_NO_MAPCHANGE);
    dcedTankFrustration = -1;
    gotTankAt = 0.0;
    tankInitiallyChosen = "";
}

Action newGame(Handle timer, any roundSerial)
{
    if (roundSerial != gSwapRoundSerial)
        return Plugin_Stop;
    TankSwap_CancelAll();
    int teamAScore = L4D2Direct_GetVSCampaignScore(0);
    int teamBScore = L4D2Direct_GetVSCampaignScore(1);

    // If it's a new game, reset the tank pool
    if (teamAScore == 0 && teamBScore == 0)
    {
        h_whosHadTank.Clear();
        h_tankQueue.Clear();
        queuedTankSteamId = "";
        tankInitiallyChosen = "";
    }

    gSwapResetDone = true;
    TankSwap_PrepareQueue();
    return Plugin_Stop;
}

/**
 * When the round ends, reset the active tank.
 */
void RoundEnd_Event(Event hEvent, const char[] eName, bool dontBroadcast)
{
    gSwapLive = true;
    gSwapRoundSerial++;
    TankSwap_CancelAll();
    queuedTankSteamId = "";
    tankInitiallyChosen = "";
}

/**
 * When a player leaves the start area, choose a tank and output to all.
 */
void PlayerLeftStartArea_Event(Event hEvent, const char[] eName, bool dontBroadcast)
{
    gSwapLive = true;
    TankSwap_CancelAll();
    tankInitiallyChosen = "";

    chooseTank(0);
    outputTankToAll(0);
}

/**
 * When the queued tank switches teams, choose a new one
 */
void PlayerTeam_Event(Event hEvent, const char[] name, bool dontBroadcast)
{
    int team = hEvent.GetInt("team");
    int oldTeam = hEvent.GetInt("oldteam");
    int client = GetClientOfUserId(hEvent.GetInt("userid"));
    char tmpSteamId[64];

    if (client < 1 || client > MaxClients)
        return;

    if (team != oldTeam)
        TankSwap_Clear(gSwapOwner[client], "TankSwap_Cancelled");

    if (team == TEAM_INFECTED && team != oldTeam)
        RequestFrame(TankSwap_PrepareQueueFrame);

    if (oldTeam == TEAM_INFECTED)
    {
        /*
        * Triggers for disconnects as well as forced-swaps and whatnot.
        * Allows us to always reliably detect when the current Tank player loses control due to unnatural reasons.
        */
        if (!IsFakeClient(client))
        {
            int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
            if (zombieClass == ZOMBIECLASS_TANK)
            {
                dcedTankFrustration = GetTankFrustration(client);
                fTankGrace = CTimer_GetRemainingTime(GetFrustrationTimer(client));

                // Slight fix due to the timer seemingly always getting stuck between 0.5s~1.2s even after Grace period has passed.
                // CTimer_IsElapsed still returns false as well.
                if (fTankGrace < 0.0 || dcedTankFrustration < 100) 
                    fTankGrace = 0.0;
            }
        }

        GetClientAuthId(client, AuthId_Steam2, tmpSteamId, sizeof(tmpSteamId));

        if (StrEqual(tankInitiallyChosen, tmpSteamId))
            initialTankLeft = GetGameTime();

        if (StrEqual(queuedTankSteamId, tmpSteamId))
        {
            RequestFrame(chooseTank, 0);
            RequestFrame(outputTankToAll, 0);
        }
    }

    if (team == TEAM_INFECTED && !IsFakeClient(client) && !StrEqual(tankInitiallyChosen, ""))
    {
        GetClientAuthId(client, AuthId_Steam2, tmpSteamId, sizeof(tmpSteamId));
        if (StrEqual(tankInitiallyChosen, tmpSteamId))
        {
            /* Not touching multiple tanks with a ten-foot pole.
            Could technically be done though.. TODO? */
            int tank = getTankPlayer();

            if (hTankDebug.BoolValue)
                PrintToConsoleAll("[TC] Tank: %N - L4D2_GetTankCount: %i - initialTankLeft: %f - gotTankAt: %f", tank, L4D2_GetTankCount(), initialTankLeft, gotTankAt);

            float window = hTankWindow.FloatValue;
            if (window > 0.0 && L4D2_GetTankCount() == 1 && tank != -1 && (gotTankAt - initialTankLeft) < window)
            {
                // Delay by a frame as player needs to "settle in"
                RequestFrame(ReplaceTank, client);
            }
            else
            {
                strcopy(queuedTankSteamId, sizeof(queuedTankSteamId), tankInitiallyChosen);
                RequestFrame(outputTankToAll, 0);
            }
        }
    }
}

/**
 * Replaces the current tank with the initially chosen Tank.
 * And requeues the old Tank.
 * 
 * @param deservingTank
 *      The player to give the Tank to.
 */
void ReplaceTank(int deservingTank)
{
    TankSwap_CancelAll();
    int oldTank = getTankPlayer();

    if (oldTank != -1 && IS_INFECTED(deservingTank))
    {
        if (hTankDebug.BoolValue)
            PrintToConsoleAll("[TC] Tank: %N being replaced by %N", oldTank, deservingTank);

        L4D_ReplaceTank(oldTank, deservingTank);

        char steamId[64];

        // Requeue the old tank        
        GetClientAuthId(oldTank, AuthId_Steam2, steamId, sizeof(steamId));
        if (h_tankQueue.FindString(steamId) == -1)
        {
            h_tankQueue.ShiftUp(0);
            h_tankQueue.SetString(0, steamId);
        }

        int index = h_whosHadTank.FindString(steamId);
        if (index != -1)
            h_whosHadTank.Erase(index);

        // Remove the deserving tank from the queue if they're in it
        GetClientAuthId(deservingTank, AuthId_Steam2, steamId, sizeof(steamId));
        index = h_tankQueue.FindString(steamId);
        if (index != -1)
            h_tankQueue.Erase(index);

        index = h_whosHadTank.FindString(steamId);
        if (index == -1)
            h_whosHadTank.PushString(steamId);                
    }
    else if (hTankDebug.BoolValue)
        PrintToConsoleAll("[TC] oldTank: %i and deservingTank: is%s valid", oldTank, IS_INFECTED(deservingTank) ? "" : " NOT");
}

/**
 * When the tank dies, requeue a player to become tank (for finales)
 */
void PlayerDeath_Event(Event hEvent, const char[] eName, bool dontBroadcast)
{
    int victim = GetClientOfUserId(hEvent.GetInt("userid"));
    
    if (victim && IS_VALID_INFECTED(victim) && gotTankAt > 0.0)
    {
        int zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
        if (zombieClass == ZOMBIECLASS_TANK) 
        {
            if (hTankDebug.BoolValue)
                PrintToConsoleAll("[TC] Tank died (player_death), choosing a new tank");

            tankInitiallyChosen = "";
            chooseTank(0);
            gotTankAt = 0.0;
            dcedTankFrustration = -1;
        }
    }
}

/*=========================================================================
|                               Commands                                  |
=========================================================================*/


/**
 * When a player wants to find out whos becoming tank,
 * output to them.
 */
Action Tank_Cmd(int client, int args)
{
    // Only output if client is in-game and we have a queued tank
    if (!client || !IsClientInGame(client) || StrEqual(queuedTankSteamId, ""))
        return Plugin_Handled;
    
    int tankClientId = getInfectedPlayerBySteamId(queuedTankSteamId);

    if (tankClientId != -1 && (hTankPrint.BoolValue || IS_INFECTED(client) || IS_SPECTATOR(client)))
    {
        if (client == tankClientId) 
            CPrintToChat(client, "%t %t", "TagSelection", "YouBecomeTank");
        else 
            CPrintToChat(client, "%t %t", "TagSelection", "BecomeTank", tankClientId);
    }
    
    return Plugin_Handled;
}


/* Tank list: observation only. Ready-stage queue preparation happens separately. */
int TankList_FindClient(const char[] steamId)
{
    if (steamId[0] == '\0')
        return 0;

    char auth[64];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != TEAM_INFECTED)
            continue;
        if (GetClientAuthId(i, AuthId_Steam2, auth, sizeof(auth)) && StrEqual(auth, steamId))
            return i;
    }
    return 0;
}

Action TankList_Cmd(int client, int args)
{
    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        if (client == 0)
            ReplyToCommand(client, "%T", "TankList_Console", LANG_SERVER);
        return Plugin_Handled;
    }
    if (h_tankQueue == null)
    {
        CPrintToChat(client, "%t %t", "TankList_Tag", "TankList_Uninitialized");
        return Plugin_Handled;
    }

    int players[MAXPLAYERS + 1];
    bool seen[MAXPLAYERS + 1];
    int count = 0;

    // Overrides (sm_givetank or selection forwards) take precedence over the queue.
    int selected = TankList_FindClient(queuedTankSteamId);
    if (selected > 0)
    {
        players[count++] = selected;
        seen[selected] = true;
    }

    char steamId[64];
    for (int i = 0; i < h_tankQueue.Length && count < MAXPLAYERS; i++)
    {
        h_tankQueue.GetString(i, steamId, sizeof(steamId));
        int candidate = TankList_FindClient(steamId);
        if (candidate <= 0 || seen[candidate])
            continue;
        players[count++] = candidate;
        seen[candidate] = true;
    }

    if (count == 0)
    {
        CPrintToChat(client, "%t %t", "TankList_Tag", "TankList_Empty");
        return Plugin_Handled;
    }

    CPrintToChat(client, "%t %t", "TankList_Tag", "TankList_Title");
    char name[MAX_NAME_LENGTH];
    int number = 0;
    for (int i = 0; i < count; i++)
    {
        int target = players[i];
        if (!IsClientInGame(target) || IsFakeClient(target) || GetClientTeam(target) != TEAM_INFECTED)
            continue;
        GetClientName(target, name, sizeof(name));
        // Names are data, never a format string. No public broadcast.
        CPrintToChat(client, "%t", "TankList_Entry", ++number, name);
    }
    return Plugin_Handled;
}

/**
 * Shuffle the tank (randomly give to another player in
 * the pool.
 */
Action TankShuffle_Cmd(int client, int args)
{
    tankInitiallyChosen = "";

    chooseTank(0);
    outputTankToAll(0);
    
    return Plugin_Handled;
}

/**
 * Give the tank to a specific player.
 */
Action GiveTank_Cmd(int client, int args)
{
    if (client && !IsClientInGame(client))
        return Plugin_Handled;

    // Who are we targetting?
    char arg1[32];
    GetCmdArg(1, arg1, sizeof(arg1));
    
    // Try and find a matching player
    int target = FindTarget(client, arg1);

    if (target == -1 || !IsClientInGame(target) || IsFakeClient(target))
    {
        CReplyToCommand(client, "%t %t", "TagControl", "InvalidTarget");
        return Plugin_Handled;
    }

    // Checking if on our desired team
    if (!IS_INFECTED(target))
    {
        CReplyToCommand(client, "%t %t", "TagControl", "NoInfected", target);
        return Plugin_Handled;
    }
    
    TankSwap_CancelAll();

    // Set the tank
    char steamId[64];
    GetClientAuthId(target, AuthId_Steam2, steamId, sizeof(steamId));

    strcopy(queuedTankSteamId, sizeof(queuedTankSteamId), steamId);
    strcopy(tankInitiallyChosen, sizeof(tankInitiallyChosen), steamId);

    outputTankToAll(0);
    
    return Plugin_Handled;
}


/*=========================================================================
|                                 Stocks                                  |
=========================================================================*/


/**
 * Selects a player on the infected team from random who hasn't been
 * tank and gives it to them.
 */
void chooseTank(any data)
{
    TankSwap_CancelAll();
    // Allow other plugins to override tank selection.
    char sOverrideTank[64];
    sOverrideTank[0] = '\0';
    Call_StartForward(hForwardOnTankSelection);
    Call_PushStringEx(sOverrideTank, sizeof(sOverrideTank), SM_PARAM_STRING_UTF8, SM_PARAM_COPYBACK);
    Call_Finish();

    if (!StrEqual(sOverrideTank, ""))
    {
        strcopy(queuedTankSteamId, sizeof(queuedTankSteamId), sOverrideTank);
        return;
    }

    queuedTankSteamId = "";

    int nextTankIndex = PeekNextTankIndexInTheQueue();

    if (nextTankIndex == -1)
    {
        EnqueueNewInfectedPlayers();
        nextTankIndex = PeekNextTankIndexInTheQueue();
    }

    if (nextTankIndex == -1)
    {
        RemoveAllInfectedFrom(h_tankQueue);
        RemoveAllInfectedFrom(h_whosHadTank);
        EnqueueNewInfectedPlayers();
        nextTankIndex = PeekNextTankIndexInTheQueue();
    }

    if (nextTankIndex == -1)
        return;

    char steamId[64];

    h_tankQueue.GetString(nextTankIndex, steamId, sizeof(steamId));

    strcopy(queuedTankSteamId, sizeof(queuedTankSteamId), steamId);

    if (StrEqual(tankInitiallyChosen, ""))
        strcopy(tankInitiallyChosen, sizeof(tankInitiallyChosen), steamId);
}

/**
 * Sets the amount of tickets for a particular player, essentially giving them tank.
 */
void setTankTickets(const char[] steamId, int tickets)
{
    int tankClientId = getInfectedPlayerBySteamId(steamId);
    
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IS_VALID_INFECTED(i) && !IsFakeClient(i))
            L4D2Direct_SetTankTickets(i, (i == tankClientId) ? tickets : 0);
    }
}

/**
 * Output who will become tank
 */
void outputTankToAll(any data)
{
    int tankClientId = getInfectedPlayerBySteamId(queuedTankSteamId);
    
    if (tankClientId != -1)
    {
        for (int i = 1; i <= MaxClients; i++) 
        {
            if (!IsClientInGame(i) || (!hTankPrint.BoolValue && !IS_INFECTED(i) && !IS_SPECTATOR(i)))
                continue;

            if (tankClientId == i) 
                CPrintToChat(i, "%t %t", "TagSelection", "YouBecomeTank");
            else 
                CPrintToChat(i, "%t %t", "TagSelection", "BecomeTank", tankClientId);
        }
    }
}

/**
 * Retrieves the current Tank player.
 * 
 * @return
 *     The tank's client index or -1 if not found.
 */
int getTankPlayer()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IS_INFECTED(i) || IsFakeClient(i))
            continue;
        
        int zombieClass = GetEntProp(i, Prop_Send, "m_zombieClass");
        
        if (zombieClass == ZOMBIECLASS_TANK)
            return i;
    }

    return -1;
}

/**
 * Retrieves a player's client index by their steam id.
 * 
 * @param steamId
 *     The steam id string to look for.
 * 
 * @return
 *     The player's client index or -1 if not found.
 */
int getInfectedPlayerBySteamId(const char[] steamId) 
{
    char tmpSteamId[64];
   
    for (int i = 1; i <= MaxClients; i++) 
    {
        if (!IS_VALID_INFECTED(i))
            continue;

        GetClientAuthId(i, AuthId_Steam2, tmpSteamId, sizeof(tmpSteamId));
        
        if (StrEqual(steamId, tmpSteamId))
            return i;
    }
    
    return -1;
}

void SetTankFrustration(int iTankClient, int iFrustration) 
{
    if (iFrustration >= 0 && iFrustration <= 100)
        SetEntProp(iTankClient, Prop_Send, "m_frustration", 100-iFrustration);
}

int GetTankFrustration(int iTankClient) 
{
    return 100 - GetEntProp(iTankClient, Prop_Send, "m_frustration");
}

CountdownTimer GetFrustrationTimer(int client)
{
    static int s_iOffs_m_frustrationTimer = -1;

    if (s_iOffs_m_frustrationTimer == -1)
        s_iOffs_m_frustrationTimer = FindSendPropInfo("CTerrorPlayer", "m_frustration") + 4;
    
    return view_as<CountdownTimer>(GetEntityAddress(client) + view_as<Address>(s_iOffs_m_frustrationTimer));
}

int PeekNextTankIndexInTheQueue()
{
    if (h_tankQueue.Length == 0)
        return -1;

    char steamId[64];

    for (int i = 0; i < h_tankQueue.Length; i++)
    {
        h_tankQueue.GetString(i, steamId, sizeof(steamId));

        int client = getInfectedPlayerBySteamId(steamId);
        if (client != -1)
            return i;
    }

    return -1;
}

void EnqueueNewInfectedPlayers()
{
    char steamId[64];

    int start = h_tankQueue.Length;
    int end = -1;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != TEAM_INFECTED)
            continue;
        
        if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId)))
            continue;

        if (h_tankQueue.FindString(steamId) != -1 || h_whosHadTank.FindString(steamId) != -1)
            continue;

        TankSwap_CancelAll();
        h_tankQueue.PushString(steamId);

        end = h_tankQueue.Length - 1;
    }

    if (end != -1)
        ShuffleArray(h_tankQueue, start, end);
}

void RemoveAllInfectedFrom(ArrayList arrayList)
{
    char steamId[64];

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client) || GetClientTeam(client) != TEAM_INFECTED)
            continue;
        
        GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

        int index = arrayList.FindString(steamId);
        if (index != -1)
            arrayList.Erase(index);
    }
}

void ShuffleArray(ArrayList arrayList, int start, int end)
{
    if (start == end)
        return;

    int swaps = (end - start + 1) * 2;

    for (int i = 0; i < swaps; i++)
    {
        int index1 = GetRandomInt(start, end);
        int index2 = GetRandomInt(start, end);

        if (index1 == index2)
            continue;

        arrayList.SwapAt(index1, index2);
    }
}

/**
 * Check if the translation file exists
 *
 * @param translation	Translation name.
 * @noreturn
 */
stock void LoadTranslation(const char[] translation)
{
	char
		sPath[PLATFORM_MAX_PATH],
		sName[64];

	FormatEx(sName, sizeof(sName), "translations/%s.txt", translation);
	BuildPath(Path_SM, sPath, sizeof(sPath), sName);
	if (!FileExists(sPath))
		SetFailState("Missing translation file %s.txt", translation);

	LoadTranslations(translation);
}
/* Consensual swaps: request tokens identify menus; userids identify connections. */
bool TankSwap_InReady()
{
    return !gSwapLive && IsInReady();
}

bool TankSwap_Eligible(int client, char[] auth, int maxlength)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client)
        || IsFakeClient(client) || GetClientTeam(client) != TEAM_INFECTED)
        return false;
    if (!GetClientAuthId(client, AuthId_Steam2, auth, maxlength))
        return false;
    return h_whosHadTank.FindString(auth) == -1
        && h_tankQueue.FindString(auth) != -1;
}

void TankSwap_Message(int client, const char[] phrase)
{
    if (client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client))
        CPrintToChat(client, "%t %t", "TankList_Tag", phrase);
}

void TankSwap_Clear(int owner, const char[] phrase)
{
    if (owner < 1 || owner > MaxClients || gSwapToken[owner] == 0)
        return;
    int from = GetClientOfUserId(gSwapFromUserId[owner]);
    int to = GetClientOfUserId(gSwapToUserId[owner]);
    gSwapToken[owner] = 0;
    // Clear by owner too, including disconnected clients whose userid no longer resolves.
    for (int i = 1; i <= MaxClients; i++)
        if (gSwapOwner[i] == owner)
            gSwapOwner[i] = 0;
    if (phrase[0] != '\0')
    {
        TankSwap_Message(from, phrase);
        TankSwap_Message(to, phrase);
    }
}

void TankSwap_CancelAll()
{
    for (int i = 1; i <= MaxClients; i++)
        TankSwap_Clear(i, "TankSwap_Cancelled");
}

public void OnClientDisconnect(int client)
{
    TankSwap_Clear(gSwapOwner[client], "TankSwap_Cancelled");
}

public void OnMapEnd()
{
    gSwapLive = true;
    gSwapRoundSerial++;
    TankSwap_CancelAll();
}

public void OnRoundIsLivePre()
{
    gSwapLive = true;
    TankSwap_CancelAll();
}

public void OnClientPostAdminCheck(int client)
{
    RequestFrame(TankSwap_PrepareQueueFrame);
}

void TankSwap_PrepareQueueFrame(any data)
{
    TankSwap_PrepareQueue();
}

void TankSwap_PrepareQueue()
{
    if (!gSwapResetDone || !TankSwap_InReady())
        return;
    if (PeekNextTankIndexInTheQueue() == -1 || queuedTankSteamId[0] == '\0')
        chooseTank(0);
    // Late joiners enter only the new tail; existing players keep their slots.
    EnqueueNewInfectedPlayers();
}

bool TankSwap_NormalSelection()
{
    int head = PeekNextTankIndexInTheQueue();
    if (head == -1)
        return false;
    char auth[64];
    h_tankQueue.GetString(head, auth, sizeof(auth));
    // A third-party/admin override is not a queue position: do not silently undo it.
    return StrEqual(auth, queuedTankSteamId);
}

Action TankSwap_Cmd(int client, int args)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
    {
        if (client == 0)
            ReplyToCommand(client, "%T", "TankSwap_Console", LANG_SERVER);
        return Plugin_Handled;
    }
    if (!TankSwap_InReady())
    {
        TankSwap_Message(client, "TankSwap_ReadyOnly");
        return Plugin_Handled;
    }
    if (!gSwapResetDone)
    {
        TankSwap_Message(client, "TankSwap_Initializing");
        return Plugin_Handled;
    }
    TankSwap_PrepareQueue();
    char auth[64];
    if (!TankSwap_Eligible(client, auth, sizeof(auth)))
    {
        TankSwap_Message(client, "TankSwap_Ineligible");
        return Plugin_Handled;
    }
    if (gSwapOwner[client] != 0)
    {
        TankSwap_Message(client, "TankSwap_Busy");
        return Plugin_Handled;
    }
    if (!TankSwap_NormalSelection())
    {
        TankSwap_Message(client, "TankSwap_Override");
        return Plugin_Handled;
    }
    Menu menu = new Menu(TankSwap_SelectHandler);
    char text[192], item[48], name[MAX_NAME_LENGTH];
    FormatEx(text, sizeof(text), "%T", "TankSwap_SelectTitle", client);
    menu.SetTitle(text);
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == client || gSwapOwner[i] != 0 || !TankSwap_Eligible(i, auth, sizeof(auth)))
            continue;
        // Round serial also prevents a selection menu from a previous round being used.
        FormatEx(item, sizeof(item), "%d:%d", gSwapRoundSerial, GetClientUserId(i));
        GetClientName(i, name, sizeof(name));
        menu.AddItem(item, name);
    }
    if (menu.ItemCount == 0)
    {
        delete menu;
        TankSwap_Message(client, "TankSwap_NoTarget");
        return Plugin_Handled;
    }
    menu.ExitButton = true;
    menu.Display(client, TANK_SWAP_SECONDS);
    return Plugin_Handled;
}

public int TankSwap_SelectHandler(Menu menu, MenuAction action, int client, int itemIndex)
{
    if (action == MenuAction_End)
        delete menu;
    else if (action == MenuAction_Select)
    {
        char item[48], parts[2][24];
        menu.GetItem(itemIndex, item, sizeof(item));
        if (ExplodeString(item, ":", parts, sizeof(parts), sizeof(parts[])) != 2)
            return 0;
        if (StringToInt(parts[0]) != gSwapRoundSerial)
        {
            TankSwap_Message(client, "TankSwap_Cancelled");
            return 0;
        }
        TankSwap_Request(client, GetClientOfUserId(StringToInt(parts[1])));
    }
    return 0;
}

void TankSwap_Request(int from, int to)
{
    if (!TankSwap_InReady() || !gSwapResetDone)
    {
        TankSwap_Message(from, "TankSwap_ReadyOnly");
        return;
    }
    char fromAuth[64], toAuth[64];
    if (from == to || !TankSwap_Eligible(from, fromAuth, sizeof(fromAuth))
        || !TankSwap_Eligible(to, toAuth, sizeof(toAuth)))
    {
        TankSwap_Message(from, "TankSwap_Ineligible");
        return;
    }
    if (gSwapOwner[from] != 0 || gSwapOwner[to] != 0)
    {
        TankSwap_Message(from, "TankSwap_Busy");
        return;
    }
    if (!TankSwap_NormalSelection())
    {
        TankSwap_Message(from, "TankSwap_Override");
        return;
    }
    gSwapOwner[from] = from;
    gSwapOwner[to] = from;
    gSwapToken[from] = ++gSwapSerial;
    gSwapDeadline[from] = GetEngineTime() + float(TANK_SWAP_SECONDS);
    gSwapFromUserId[from] = GetClientUserId(from);
    gSwapToUserId[from] = GetClientUserId(to);
    gSwapFromIndex[from] = h_tankQueue.FindString(fromAuth);
    gSwapToIndex[from] = h_tankQueue.FindString(toAuth);
    strcopy(gSwapFromAuth[from], sizeof(gSwapFromAuth[]), fromAuth);
    strcopy(gSwapToAuth[from], sizeof(gSwapToAuth[]), toAuth);

    Menu menu = new Menu(TankSwap_ConfirmHandler);
    char text[256], item[48], name[MAX_NAME_LENGTH];
    GetClientName(from, name, sizeof(name));
    FormatEx(text, sizeof(text), "%T", "TankSwap_ConfirmTitle", to, name, TANK_SWAP_SECONDS);
    menu.SetTitle(text);
    FormatEx(item, sizeof(item), "%d:%d:1", gSwapFromUserId[from], gSwapToken[from]);
    FormatEx(text, sizeof(text), "%T", "TankSwap_Accept", to);
    menu.AddItem(item, text);
    FormatEx(item, sizeof(item), "%d:%d:0", gSwapFromUserId[from], gSwapToken[from]);
    FormatEx(text, sizeof(text), "%T", "TankSwap_Decline", to);
    menu.AddItem(item, text);
    menu.ExitButton = true;
    if (!menu.Display(to, TANK_SWAP_SECONDS))
    {
        TankSwap_Clear(from, "TankSwap_Cancelled");
        return;
    }
    DataPack pack;
    CreateDataTimer(float(TANK_SWAP_SECONDS), TankSwap_Timeout, pack, TIMER_FLAG_NO_MAPCHANGE);
    pack.WriteCell(gSwapFromUserId[from]);
    pack.WriteCell(gSwapToken[from]);
    GetClientName(to, name, sizeof(name));
    CPrintToChat(from, "%t %t", "TankList_Tag", "TankSwap_Sent", name, TANK_SWAP_SECONDS);
}

public Action TankSwap_Timeout(Handle timer, DataPack pack)
{
    pack.Reset();
    int from = GetClientOfUserId(pack.ReadCell());
    int token = pack.ReadCell();
    if (from > 0 && gSwapToken[from] == token)
        TankSwap_Clear(from, "TankSwap_Expired");
    return Plugin_Stop;
}

public int TankSwap_ConfirmHandler(Menu menu, MenuAction action, int client, int itemIndex)
{
    if (action == MenuAction_End)
        delete menu;
    else if (action == MenuAction_Select || action == MenuAction_Cancel)
    {
        // Cancel has no selected item. Item zero still carries this menu's unique token.
        char item[48], parts[3][24];
        menu.GetItem(action == MenuAction_Select ? itemIndex : 0, item, sizeof(item));
        if (ExplodeString(item, ":", parts, sizeof(parts), sizeof(parts[])) != 3)
            return 0;
        int from = GetClientOfUserId(StringToInt(parts[0]));
        int token = StringToInt(parts[1]);
        if (from <= 0 || gSwapToken[from] != token
            || client < 1 || client > MaxClients || !IsClientConnected(client)
            || gSwapToUserId[from] != GetClientUserId(client))
        {
            if (action == MenuAction_Select)
                TankSwap_Message(client, "TankSwap_Cancelled");
            return 0;
        }
        if (action == MenuAction_Select && GetEngineTime() >= gSwapDeadline[from])
        {
            TankSwap_Clear(from, "TankSwap_Expired");
            return 0;
        }
        if (action == MenuAction_Cancel || StringToInt(parts[2]) == 0)
        {
            TankSwap_Clear(from, action == MenuAction_Cancel && itemIndex == MenuCancel_Timeout
                ? "TankSwap_Expired" : "TankSwap_Declined");
            return 0;
        }
        char fromAuth[64], toAuth[64];
        if (!TankSwap_InReady() || !gSwapResetDone
            || !TankSwap_Eligible(from, fromAuth, sizeof(fromAuth))
            || !TankSwap_Eligible(client, toAuth, sizeof(toAuth))
            || !StrEqual(fromAuth, gSwapFromAuth[from])
            || !StrEqual(toAuth, gSwapToAuth[from])
            || h_tankQueue.FindString(fromAuth) != gSwapFromIndex[from]
            || h_tankQueue.FindString(toAuth) != gSwapToIndex[from]
            || !TankSwap_NormalSelection())
        {
            TankSwap_Clear(from, "TankSwap_Cancelled");
            return 0;
        }
        // Exactly two cells change. Never shuffle or rebuild the queue on acceptance.
        h_tankQueue.SetString(gSwapFromIndex[from], toAuth);
        h_tankQueue.SetString(gSwapToIndex[from], fromAuth);
        TankSwap_ExchangeSelection(queuedTankSteamId, sizeof(queuedTankSteamId), fromAuth, toAuth);
        TankSwap_ExchangeSelection(tankInitiallyChosen, sizeof(tankInitiallyChosen), fromAuth, toAuth);
        TankSwap_Clear(from, "TankSwap_Success");
        TankSwap_CancelAll();
        TankList_Cmd(from, 0);
        TankList_Cmd(client, 0);
    }
    return 0;
}

void TankSwap_ExchangeSelection(char[] selected, int maxlength, const char[] fromAuth, const char[] toAuth)
{
    if (StrEqual(selected, fromAuth))
        strcopy(selected, maxlength, toAuth);
    else if (StrEqual(selected, toAuth))
        strcopy(selected, maxlength, fromAuth);
}
