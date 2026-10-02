#if defined _readyup_panel_included
 #endinput
#endif
#define _readyup_panel_included

static Footer
	cmdFooter;
	
static int
	curCmd;

static bool
	showBonusInfo;

static const char 
	hintPhrase[2][] = {"HintUnready", "HintReady"},
	readySymbol[2][] = {"☐", "☑"},
	teamReadySymbol[2][] = {" [X]", " [√]"};

void InitPanel()
{
	if (cmdFooter == null)
	{
		cmdFooter = new Footer();
		cmdFooter.Add("->1. !ready|!r / !unready|!nr-准备/取消准备");
		cmdFooter.Add("->2. !slots #-设置服务器位置");
		cmdFooter.Add("->3. !voteboss <tank> <witch> -设置boss位置");
		cmdFooter.Add("->4. !match / !rmatch-加载/卸载插件");
		cmdFooter.Add("->5. !show / !hide-显示/隐藏准备菜单");
		cmdFooter.Add("->6. !setscores <survs> <inf>-设置双方分数");
		cmdFooter.Add("->7. !lerps-查看所有人lerp值");
		cmdFooter.Add("->8. !secondary-设置拾取副武器切换");
		cmdFooter.Add("->9. !forcestart / !fs-管理员强开");
		cmdFooter.Add("->10. !mix / !mixmap-队长选人/组合地图");
		cmdFooter.Add("->11. !shuffle / !shuffle-随机分队");
	}
	
	curCmd = 0;
	showBonusInfo = false;
	CreateTimer(1.0, MenuRefresh_Timer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(4.0, MenuCmd_Timer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
}

int DummyHandler(Handle menu, MenuAction action, int param1, int param2) { return 1; }

Action MenuRefresh_Timer(Handle timer)
{
	if (inReadyUp)
	{
		UpdatePanel();
		return Plugin_Continue;
	}
	return Plugin_Stop;
}

Action MenuCmd_Timer(Handle timer)
{
	if (inReadyUp)
	{
		if (cmdFooter.Length)
		{
			curCmd = (curCmd + 1) % cmdFooter.Length;
		}

		showBonusInfo = !showBonusInfo;
		return Plugin_Continue;
	}
	return Plugin_Stop;
}

void UpdatePanel()
{
	char survivorBuffer[400] = "";
	char infectedBuffer[400] = "";
	char casterBuffer[300] = "";
	char specBuffer[200] = "";
	int playerCount = 0;
	int casterCount = 0;
	int specCount = 0;

	Panel menuPanel = new Panel();

	char ServerBuffer[128];
	char ServerName[32];
	char cfgName[32];

	int iPassTime = RoundToFloor(GetGameTime() - fStartTimestamp);
	
	bool isTeamReadyMode = readyUpMode == ReadyMode_TeamReady;
	int survivorReady = IsTeamReady(L4D2Team_Survivor);
	int infectedReady = IsTeamReady(L4D2Team_Infected);

	g_cvServerNamer.GetString(ServerName, sizeof(ServerName));
	
	l4d_ready_cfg_name.GetString(cfgName, sizeof(cfgName));
	FormatEx(ServerBuffer, sizeof(ServerBuffer), "< %s [ %d/%d ] >\n< %s >", ServerName, GetSeriousClientCount(), FindConVar("sv_maxplayers").IntValue, cfgName);
	menuPanel.DrawText(ServerBuffer);
	
	FormatTime(ServerBuffer, sizeof(ServerBuffer), "< %Y/%m/%d - %H:%M >");
	Format(ServerBuffer, sizeof(ServerBuffer), "%s (%02d:%02d)", ServerBuffer, iPassTime / 60, iPassTime % 60);
	menuPanel.DrawText(ServerBuffer);
	menuPanel.DrawText(" ");

	// Read campaign scores directly from GameRules. This avoids calling
	// Left4DHooks director natives from the 1-second panel refresh path.
	bool teamsFlipped = GameRules_GetProp("m_bAreTeamsFlipped") != 0;
	int survivorTeamIndex = teamsFlipped ? 1 : 0;
	int infectedTeamIndex = teamsFlipped ? 0 : 1;
	int survivorScore = GameRules_GetProp("m_iCampaignScore", 4, survivorTeamIndex);
	int infectedScore = GameRules_GetProp("m_iCampaignScore", 4, infectedTeamIndex);
	int scoreDiff = survivorScore - infectedScore;

	int maxHealthBonus = 0;
	int maxDamageBonus = 0;
	int maxPillsBonus = 0;
	int maxDistanceScore = 0;

	bool scoremodAvailable =
		GetFeatureStatus(FeatureType_Native, "SMPlus_GetMaxHealthBonus") == FeatureStatus_Available &&
		GetFeatureStatus(FeatureType_Native, "SMPlus_GetMaxDamageBonus") == FeatureStatus_Available &&
		GetFeatureStatus(FeatureType_Native, "SMPlus_GetMaxPillsBonus") == FeatureStatus_Available;

	if (scoremodAvailable)
	{
		maxHealthBonus = SMPlus_GetMaxHealthBonus();
		maxDamageBonus = SMPlus_GetMaxDamageBonus();
		maxPillsBonus = SMPlus_GetMaxPillsBonus();

		// Hybrid ScoreMod defines HB + DB as:
		// map distance * bonus_per_survivor_multiplier * survivor_limit.
		ConVar bonusMultiplier = FindConVar("sm2_bonus_per_survivor_multiplier");
		if (bonusMultiplier != null && survivor_limit.IntValue > 0)
		{
			float divisor = bonusMultiplier.FloatValue * float(survivor_limit.IntValue);
			if (divisor > 0.0)
			{
				maxDistanceScore = RoundToNearest(float(maxHealthBonus + maxDamageBonus) / divisor);
			}
		}
	}

	if (showBonusInfo && scoremodAvailable)
	{
		int totalBonus = maxHealthBonus + maxDamageBonus + maxPillsBonus;
		FormatEx(ServerBuffer, sizeof(ServerBuffer), "奖励分: %d [HB:%d | DB:%d | PB:%d]", totalBonus, maxHealthBonus, maxDamageBonus, maxPillsBonus);
	}
	else
	{
		FormatEx(ServerBuffer, sizeof(ServerBuffer), "总分差: [%d] | 最大路程分: [%d]", scoreDiff, maxDistanceScore);
	}
	menuPanel.DrawText(ServerBuffer);
	
	
	
	
	char nameBuf[64];
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client))
		{
			++playerCount;
			GetClientFixedName(client, nameBuf, sizeof(nameBuf));
			// Only display cached playtime for Survivors and Infected.
			// Spectators still query and cache playtime in playtime.inc.
			int playtimeTeam = GetClientTeam(client);
			if (playtimeTeam == 2 || playtimeTeam == 3)
			{
				ReadyupPlaytime_Append(client, nameBuf, sizeof(nameBuf));
			}
			
			if (IsPlayer(client))
			{
				bool type = (GetClientTeam(client) == L4D2Team_Survivor);
				int isReady = view_as<int>(IsPlayerReady(client));
				
				switch (readyUpMode)
				{
					case ReadyMode_PlayerReady:
					{
						if (!inLiveCountdown) PrintHintText(client, "%t", hintPhrase[isReady]);
						Format(nameBuf, sizeof(nameBuf), "%s %s%s\n", readySymbol[isReady], nameBuf, IsPlayerAfk(client) ? " [AFK]" : "");
					}
					case ReadyMode_AutoStart:
					{
						Format(nameBuf, sizeof(nameBuf), "%s\n", nameBuf);
					}
					case ReadyMode_TeamReady:
					{
						if (!inLiveCountdown) PrintHintText(client, "%t", hintPhrase[type ? survivorReady : infectedReady]);
						Format(nameBuf, sizeof(nameBuf), "%s%s\n", nameBuf, IsPlayerAfk(client) ? " [AFK]" : "");
					}
				}
				type ? StrCat(survivorBuffer, sizeof(survivorBuffer), nameBuf) : StrCat(infectedBuffer, sizeof(infectedBuffer), nameBuf);
			}
			else
			{
				++specCount;
				if (casterSystemAvailable && IsClientCaster(client))
				{
					++casterCount;
					Format(nameBuf, sizeof(nameBuf), "%s\n", nameBuf);
					StrCat(casterBuffer, sizeof(casterBuffer), nameBuf);
				}
				else
				{
					if (playerCount <= l4d_ready_max_players.IntValue)
					{
						Format(nameBuf, sizeof(nameBuf), "%s\n", nameBuf);
						StrCat(specBuffer, sizeof(specBuffer), nameBuf);
					}
				}
			}
		}
	}

	if (nativeFooter.Length)
	{
		//menuPanel.DrawText(" ");
		for (int i = 0; i < nativeFooter.Length; i++)
		{
			menuPanel.DrawText(FooterGet(nativeFooter, i));
		}
		menuPanel.DrawText(" ");
	}

	int textCount = 0;
	int bufLen = strlen(survivorBuffer);
	if (bufLen != 0)
	{
		survivorBuffer[bufLen] = '\0';
		ReplaceString(survivorBuffer, sizeof(survivorBuffer), "#", "_");
		FormatEx(nameBuf, sizeof(nameBuf), "->%d. 生还方 [%d]%s", ++textCount, survivorScore, isTeamReadyMode ? teamReadySymbol[survivorReady] : "");
		menuPanel.DrawText(nameBuf);
		menuPanel.DrawText(survivorBuffer);
	}

	bufLen = strlen(infectedBuffer);
	if (bufLen != 0)
	{
		infectedBuffer[bufLen] = '\0';
		ReplaceString(infectedBuffer, sizeof(infectedBuffer), "#", "_");
		FormatEx(nameBuf, sizeof(nameBuf), "->%d. 特感方 [%d]%s", ++textCount, infectedScore, isTeamReadyMode ? teamReadySymbol[infectedReady] : "");
		menuPanel.DrawText(nameBuf);
		menuPanel.DrawText(infectedBuffer);
	}
	
	if (specCount && textCount) menuPanel.DrawText(" ");

	if (casterSystemAvailable)
	{
		bufLen = strlen(casterBuffer);
		if (bufLen != 0)
		{
			casterBuffer[bufLen] = '\0';
			FormatEx(nameBuf, sizeof(nameBuf), "->%d. 解说%s", ++textCount, casterCount > 1 ? "s" : "");
			menuPanel.DrawText(nameBuf);
			ReplaceString(casterBuffer, sizeof(casterBuffer), "#", "_", true);
			menuPanel.DrawText(casterBuffer);
		}
	}
	
	bufLen = strlen(specBuffer);
	if (bufLen != 0)
	{
		specBuffer[bufLen] = '\0';
		FormatEx(nameBuf, sizeof(nameBuf), "->%d. 旁观者", ++textCount);
		menuPanel.DrawText(nameBuf);
		ReplaceString(specBuffer, sizeof(specBuffer), "#", "_");
		if (playerCount > l4d_ready_max_players.IntValue && specCount - casterCount > 1)
			FormatEx(specBuffer, sizeof(specBuffer), "**Many** (%d)", specCount - casterCount);
		menuPanel.DrawText(specBuffer);
	}

	menuPanel.DrawText(" ");
	menuPanel.DrawText("指令:");
	menuPanel.DrawText(FooterGet(cmdFooter, curCmd));

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client) && !IsPlayerHiddenPanel(client)) 
		{
			if (BuiltinVote_IsVoteInProgress() && IsClientInBuiltinVotePool(client))
			{
				continue;
			}
			
			if (Game_IsVoteInProgress())
			{
				int voteteam = Game_GetVoteTeam();
				if (voteteam == -1 || voteteam == GetClientTeam(client))
				{
					continue;
				}
			}
			
			switch (GetClientMenu(client))
			{
				case MenuSource_External, MenuSource_Normal: continue;
			}
			
			menuPanel.Send(client, DummyHandler, 1);
		}
	}
	
	delete menuPanel;
}