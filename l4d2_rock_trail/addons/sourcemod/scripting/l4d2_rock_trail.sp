
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"

#define TEAM_SPECTATOR 1
#define TEAM_SURVIVOR  2
#define TEAM_INFECTED  3

ConVar g_cvEnable;
ConVar g_cvTeam;
ConVar g_cvColor;
ConVar g_cvAlpha;
ConVar g_cvLife;
ConVar g_cvWidth;
ConVar g_cvEndWidth;
ConVar g_cvFade;
ConVar g_cvMaterial;

int g_iLaserSprite = -1;
int g_iGlowSprite = -1;

public Plugin myinfo =
{
    name = "[L4D2] Tank Rock Trail",
    author = "Fredd, Mister Game Over;Ts & UUZ改编用于药抗",
    description = "显示石头轨迹",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    char game[32];
    GetGameFolderName(game, sizeof(game));

    if (!StrEqual(game, "left4dead2", false))
    {
        SetFailState("This plugin supports L4D2 only.");
        return;
    }

    g_cvEnable = CreateConVar(
        "l4d2_rocktrail_enable",
        "1",
        "Enable Tank rock trails. 0=Off, 1=On",
        FCVAR_NOTIFY,
        true, 0.0,
        true, 1.0
    );

    g_cvTeam = CreateConVar(
        "l4d2_rocktrail_team",
        "1",
        "Visibility: 0=All, 1=Infected+Spectators, 2=Spectators, 3=Infected",
        FCVAR_NOTIFY,
        true, 0.0,
        true, 3.0
    );

    g_cvColor = CreateConVar(
        "l4d2_rocktrail_color",
        "255 0 255",
        "Tank rock trail RGB color: R G B"
    );

    g_cvAlpha = CreateConVar(
        "l4d2_rocktrail_alpha",
        "255",
        "Trail alpha: 0-255",
        FCVAR_NONE,
        true, 0.0,
        true, 255.0
    );

    g_cvLife = CreateConVar(
        "l4d2_rocktrail_life",
        "2.0",
        "Trail lifetime in seconds",
        FCVAR_NONE,
        true, 0.1,
        true, 10.0
    );

    g_cvWidth = CreateConVar(
        "l4d2_rocktrail_width",
        "10.0",
        "Trail starting width",
        FCVAR_NONE,
        true, 0.1,
        true, 100.0
    );

    g_cvEndWidth = CreateConVar(
        "l4d2_rocktrail_endwidth",
        "10.0",
        "Trail ending width",
        FCVAR_NONE,
        true, 0.0,
        true, 100.0
    );

    g_cvFade = CreateConVar(
        "l4d2_rocktrail_fade",
        "5",
        "Beam fade length: 0-255",
        FCVAR_NONE,
        true, 0.0,
        true, 255.0
    );

    g_cvMaterial = CreateConVar(
        "l4d2_rocktrail_material",
        "0",
        "Trail material: 0=Laserbeam, 1=Glow",
        FCVAR_NONE,
        true, 0.0,
        true, 1.0
    );

    CreateConVar(
        "l4d2_rocktrail_version",
        PLUGIN_VERSION,
        "Tank Rock Trail plugin version",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );

    AutoExecConfig(true, "l4d2_rocktrail");

    CacheSprites();
}

public void OnMapStart()
{
    CacheSprites();
}

void CacheSprites()
{
    g_iLaserSprite = PrecacheModel(
        "materials/sprites/laserbeam.vmt",
        true
    );

    g_iGlowSprite = PrecacheModel(
        "materials/sprites/glow.vmt",
        true
    );
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnable.BoolValue)
        return;

    if (!StrEqual(classname, "tank_rock", false))
        return;

    if (entity <= MaxClients)
        return;

    RequestFrame(Frame_CreateRockTrail, EntIndexToEntRef(entity));
}

public void Frame_CreateRockTrail(any entityRef)
{
    if (!g_cvEnable.BoolValue)
        return;

    int entity = EntRefToEntIndex(entityRef);

    if (entity == INVALID_ENT_REFERENCE)
        return;

    if (!IsValidEntity(entity))
        return;

    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));

    if (!StrEqual(classname, "tank_rock", false))
        return;

    int recipients[MAXPLAYERS + 1];
    int count = BuildRecipients(recipients);

    if (count <= 0)
        return;

    int sprite = g_cvMaterial.IntValue == 1
        ? g_iGlowSprite
        : g_iLaserSprite;

    if (sprite <= 0)
        return;

    int color[4];
    GetTrailColor(color);

    float life = g_cvLife.FloatValue;
    float width = g_cvWidth.FloatValue;
    float endWidth = g_cvEndWidth.FloatValue;
    int fadeLength = g_cvFade.IntValue;

    TE_SetupBeamFollow(
        entity,
        sprite,
        0,
        life,
        width,
        endWidth,
        fadeLength,
        color
    );

    TE_Send(recipients, count);
}

int BuildRecipients(int recipients[MAXPLAYERS + 1])
{
    int count = 0;
    int mode = g_cvTeam.IntValue;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
            continue;

        int team = GetClientTeam(client);
        bool allowed = false;

        switch (mode)
        {
            case 0:
            {
                allowed = (
                    team == TEAM_SPECTATOR ||
                    team == TEAM_SURVIVOR ||
                    team == TEAM_INFECTED
                );
            }

            case 1:
            {
                allowed = (
                    team == TEAM_SPECTATOR ||
                    team == TEAM_INFECTED
                );
            }

            case 2:
            {
                allowed = (team == TEAM_SPECTATOR);
            }

            case 3:
            {
                allowed = (team == TEAM_INFECTED);
            }
        }

        if (!allowed)
            continue;

        recipients[count] = client;
        count++;
    }

    return count;
}

void GetTrailColor(int color[4])
{
    char buffer[64];
    char parts[3][16];

    g_cvColor.GetString(buffer, sizeof(buffer));

    int count = ExplodeString(
        buffer,
        " ",
        parts,
        sizeof(parts),
        sizeof(parts[])
    );

    if (count == 3)
    {
        color[0] = ClampColor(StringToInt(parts[0]));
        color[1] = ClampColor(StringToInt(parts[1]));
        color[2] = ClampColor(StringToInt(parts[2]));
    }
    else
    {
        color[0] = 255;
        color[1] = 0;
        color[2] = 255;
    }

    color[3] = ClampColor(g_cvAlpha.IntValue);
}

int ClampColor(int value)
{
    if (value < 0)
        return 0;

    if (value > 255)
        return 255;

    return value;
}
