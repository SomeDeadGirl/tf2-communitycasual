#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <nextmap>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0.0"
#define FINAL_COUNTDOWN_SECONDS 10.0
#define SPAWN_REDUCTION_SECONDS 30.0
#define SPAWN_REDUCTION_FLOOR 60.0
#define CONTROLLER_INTERVAL 0.25
#define HUD_INIT_DELAY 1.0
#define HUD_REFRESH_SETTLE 0.75
#define HUD_REFRESH_SECONDS 0.75
#define HUD_REFRESH_COOLDOWN 3.0
#define TIMER_RECORD_SIZE 2
#define TIMER_REF 0
#define TIMER_WAS_RUNNING 1
#define MATCH_GROUP_CASUAL 7
#define VOTE_OPTION_COUNT 3
#define VOTE_UNDECIDED 3
#define CASUAL_MAP_NAME_LENGTH 128
#define SOUND_CASUAL_WIN "MatchMaking.MatchEndWinMusicCasual"
#define SOUND_CASUAL_LOSE "MatchMaking.MatchEndLoseMusicCasual"

enum CountdownPhase
{
    Countdown_None,
    Countdown_Waiting,
    Countdown_RestartPending,
    Countdown_Final
};

enum PostMatchPhase
{
    PostMatch_None,
    PostMatch_Queued,
    PostMatch_Voting,
    PostMatch_Chosen
};

public Plugin myinfo =
{
    name = "[TF2] Community Casual",
    author = "gloom",
    description = "Adds Meet Your Match's Casual into Community Servers.",
    version = PLUGIN_VERSION,
    url = "https://github.com/SomeDeadGirl"
};

/* ============================================================================
 *  STATE / SHARED MEMORY
 * ========================================================================== */

bool g_bMapRunning;
bool g_bConfigsReady;
bool g_bLoadedLate;
int g_iMapSerial;
Handle g_hController;
ConVar g_cvDebug;
ConVar g_cvTournament;
ConVar g_cvReadyMode;
ConVar g_cvStopwatch;
ConVar g_cvArenaMode;
ConVar g_cvRestartRequests[5];
ArrayList g_RoundTimers;

ConVar g_cvCountdownEnabled;
ConVar g_cvCountdownSeconds;
bool g_bAutoCountdownUsed;
bool g_bAutoCountdownPending;
ArrayList g_QueuedSpawnClients;
bool g_bHasSpawned[MAXPLAYERS + 1];
CountdownPhase g_CountdownPhase = Countdown_None;
float g_flCountdownDeadline;
float g_flOwnedRestartDeadline;
float g_flRestartRequestedAt;
float g_flNextCountdownMonitorAt;
Handle g_hCountdownHudRefresh;
bool g_bCountdownHudRefresh;
bool g_bRoundRestarted;
bool g_bHoldingPreRound;
bool g_bCountdownUsesDoors;
int g_iCountdownSerial;
int g_iCountdownReductions;
ArrayList g_HeldTimers;
ArrayList g_PausedStopwatches;
int g_iSavedTournament;
int g_iSavedReadyMode;
int g_iSavedStopwatchCvar;
int g_iSavedStopwatchFlag;
int g_iSavedWaiting;
int g_iSavedAwaitingReady;
int g_iSavedRoundsPlayed;
float g_flSavedCountdownTime;

bool g_bCountdownHudRefreshed[MAXPLAYERS + 1];
float g_flClientHudReadyAt[MAXPLAYERS + 1];
int g_iHudRefreshClients[MAXPLAYERS + 1];
float g_flNextHudRefreshAt;
bool g_bHudInitSent[MAXPLAYERS + 1];
Handle g_hClientHudInit[MAXPLAYERS + 1];
int g_iClientSummaryRun[MAXPLAYERS + 1];
bool g_bOwnMatchGroup;
int g_iOriginalMatchGroup;
ConVar g_cvDoorsEnabled;
bool g_bOwnDoorRounds;
int g_iDoorSavedRounds;
Handle g_hDoorTickTimer;
Handle g_hDoorStartTimer;
int g_iDoorSecondsRemaining;

ConVar g_cvSummaryEnabled;
ConVar g_cvNativeVoteTime;
ConVar g_cvChatTime;
ConVar g_cvNextLevel;
StringMap g_MapSchemaIds;
bool g_bSchemaLoaded;
bool g_bPostMatchAttempted;
bool g_bPostMatchArmed;
bool g_bOwnChatTime;
float g_flSavedChatTime;
int g_iOwnedChatTime;
PostMatchPhase g_PostMatchPhase;
Handle g_hEndMapTimer;
int g_iEndMapRequesterSerial;
float g_flVoteDeadline;
int g_iVoteRunSerial;
int g_iVoteOptions;
int g_iMapDefIds[VOTE_OPTION_COUNT];
char g_szVoteMaps[VOTE_OPTION_COUNT][CASUAL_MAP_NAME_LENGTH];
int g_iPlayerVotes[MAXPLAYERS + 1];
int g_iWinningMap = -1;
bool g_bSummaryTransition;
float g_flSummaryTransitionUntil;
UserMsg g_msgVguiMenu = INVALID_MESSAGE_ID;

ConVar g_cvMusicEnabled;
bool g_bFinalResultKnown;
bool g_bFinalMusicPlayed;
bool g_bFinalMusicEnabled;
int g_iFinalWinningTeam;

/* ============================================================================
 *  CORE STUFF
 * ========================================================================== */

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int errMax)
{
    g_bLoadedLate = late;
    return APLRes_Success;
}

public void OnPluginStart()
{
    if (GetEngineVersion() != Engine_TF2)
    {
        SetFailState("This plugin requires Team Fortress 2.");
    }

    g_HeldTimers = new ArrayList(TIMER_RECORD_SIZE);
    g_PausedStopwatches = new ArrayList();
    g_QueuedSpawnClients = new ArrayList();
    g_RoundTimers = new ArrayList();
    g_MapSchemaIds = new StringMap();
    CreatePluginConVars();
    RegisterCommandsAndEvents();
    AutoExecConfig(true, "tf2_casual_countdown");
}

void CreatePluginConVars()
{
    g_cvTournament = FindConVar("mp_tournament");
    g_cvReadyMode = FindConVar("mp_tournament_readymode");
    g_cvStopwatch = FindConVar("mp_tournament_stopwatch");
    g_cvNativeVoteTime = FindConVar("tf_mm_next_map_vote_time");
    g_cvChatTime = FindConVar("mp_chattime");
    g_cvNextLevel = FindConVar("nextlevel");
    g_cvArenaMode = FindConVar("tf_gamemode_arena");
    static const char restartNames[][] =
    {
        "mp_restartgame", "mp_restartround", "mp_restartgame_immediate",
        "mp_waitingforplayers_restart", "mp_waitingforplayers_cancel"
    };
    for (int i = 0; i < sizeof(restartNames); i++)
    {
        g_cvRestartRequests[i] = FindConVar(restartNames[i]);
    }
    if (g_cvTournament == null || g_cvReadyMode == null || g_cvStopwatch == null)
    {
        SetFailState("Required TF2 tournament convars were not found.");
    }

    // Owner-facing descriptions are collected here for easy editing.
    g_cvCountdownEnabled = CreateConVar("sm_casual_countdown", "1",
        "Enable Casual's warmup system.",
        FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvCountdownSeconds = CreateConVar("sm_casual_countdown_time", "150",
        "Starting countdown time in seconds (15-600).",
        FCVAR_NONE, true, 15.0, true, 600.0);
    g_cvDoorsEnabled = CreateConVar("sm_casual_doors", "1",
        "Enable the doors animation.",
        FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvSummaryEnabled = CreateConVar("sm_casual_summary", "1",
        "Enable the Casual match summary and next-map vote.",
        FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvMusicEnabled = CreateConVar("sm_casual_music", "1",
        "[QOL] Enable Casual victory/defeat music at the final match result.",
        FCVAR_NONE, true, 0.0, true, 1.0);
    g_cvDebug = CreateConVar("sm_casual_debug", "0",
        "[DEBUG] Enable server-console diagnostics and chat broadcasts.",
        FCVAR_NONE, true, 0.0, true, 1.0);

    g_cvCountdownEnabled.AddChangeHook(ConVar_FeaturesChanged);
    g_cvDoorsEnabled.AddChangeHook(ConVar_FeaturesChanged);
    g_cvSummaryEnabled.AddChangeHook(ConVar_FeaturesChanged);
    if (g_cvNativeVoteTime != null)
    {
        g_cvNativeVoteTime.AddChangeHook(ConVar_PostMatchSettingsChanged);
    }
}

void DebugPrint(const char[] format, any ...)
{
    if (!g_cvDebug.BoolValue)
    {
        return;
    }
    char message[512];
    VFormat(message, sizeof(message), format, 2);
    PrintToServer("%s", message);
}

void DebugChatAll(const char[] format, any ...)
{
    if (!g_cvDebug.BoolValue)
    {
        return;
    }
    char message[512];
    VFormat(message, sizeof(message), format, 2);
    PrintToChatAll("%s", message);
}

void RegisterCommandsAndEvents()
{
    RegAdminCmd("sm_countdown", Command_Countdown, ADMFLAG_RCON,
        "sm_countdown [seconds|stop|status] - start, cancel or inspect Casual warmup.");
    RegAdminCmd("sm_doors", Command_Doors, ADMFLAG_RCON,
        "Play the pre-match door animation without restarting the round.");
    RegAdminCmd("sm_endmap", Command_EndMap, ADMFLAG_RCON,
        "sm_endmap [map1 map2 map3|status] - END this match and run the Casual map vote.");
    AddCommandListener(Command_NextMapVote, "next_map_vote");

    HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
    HookEventEx("teamplay_game_over", Event_GameOver, EventHookMode_Pre);
    HookEventEx("tf_game_over", Event_GameOver, EventHookMode_Pre);
    HookEvent("teamplay_win_panel", Event_WinPanel, EventHookMode_Pre);
    HookEvent("teamplay_broadcast_audio", Event_BroadcastAudio, EventHookMode_Pre);
    g_msgVguiMenu = GetUserMessageId("VGUIMenu");
    if (g_msgVguiMenu != INVALID_MESSAGE_ID && GetUserMessageType() == UM_BitBuf)
    {
        HookUserMessage(g_msgVguiMenu, Message_VguiMenu, true);
    }
    else
    {
        LogError("VGUIMenu interception unavailable; the normal scoreboard may flash before the summary.");
    }
}

public void OnMapStart()
{
    g_bCountdownHudRefresh = false;
    g_hCountdownHudRefresh = null;
    g_bMapRunning = true;
    g_bConfigsReady = false;
    g_bOwnDoorRounds = false;
    g_flNextHudRefreshAt = 0.0;
    g_iMapSerial++;
    g_bAutoCountdownUsed = false;
    g_bAutoCountdownPending = false;
    g_QueuedSpawnClients.Clear();
    CacheRoundTimers();
    g_bOwnMatchGroup = false;
    g_bSchemaLoaded = false;
    g_MapSchemaIds.Clear();
    g_bPostMatchAttempted = false;
    g_bPostMatchArmed = false;
    g_PostMatchPhase = PostMatch_None;
    g_iWinningMap = -1;
    g_iVoteOptions = 0;
    g_bSummaryTransition = false;
    ResetFinalMatchAudio();
    PrepareMatchHud();
    for (int client = 1; client <= MaxClients; client++)
    {
        g_bHudInitSent[client] = false;
        g_hClientHudInit[client] = null;
        g_bCountdownHudRefreshed[client] = false;
        g_flClientHudReadyAt[client] = 0.0;
        g_iHudRefreshClients[client] = 0;
        g_iClientSummaryRun[client] = 0;
        g_iPlayerVotes[client] = VOTE_UNDECIDED;

        g_bHasSpawned[client] = g_bLoadedLate && IsClientInGame(client) && GetClientTeam(client) >= 2
            && GetEntProp(client, Prop_Send, "m_iClass") > 0;
        if (g_bLoadedLate && g_bHasSpawned[client])
        {
            g_bAutoCountdownUsed = true;
        }
        QueueClientHudInit(client);
    }
    if (g_bLoadedLate && (GameRules_GetProp("m_nRoundsPlayed") > 0
        || GameRules_GetRoundState() == RoundState_GameOver))
    {
        g_bAutoCountdownUsed = true;
    }
    g_bLoadedLate = false;
}

public void OnConfigsExecuted()
{
    g_bConfigsReady = true;
    PrepareMatchHud();
    for (int client = 1; client <= MaxClients; client++)
    {
        QueueClientHudInit(client);
    }
    ConfigureAutomaticPostMatch();
    if (g_hController == null && g_bMapRunning)
    {
        g_hController = CreateTimer(CONTROLLER_INTERVAL, Timer_Controller, 0,
            TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }
    TryStartAutomaticCountdown();
}

public void OnMapEnd()
{
    g_bMapRunning = false;
    g_bConfigsReady = false;
    g_iMapSerial++;
    g_hController = null;
    ClearAutomaticCountdownQueue();
    g_hDoorTickTimer = null;
    g_hDoorStartTimer = null;
    g_hEndMapTimer = null;
    g_hCountdownHudRefresh = null;
    for (int client = 1; client <= MaxClients; client++)
    {
        g_hClientHudInit[client] = null;
    }
    FinishCountdown(true);
    CleanupPostMatch();
    g_bOwnMatchGroup = false;
    g_bOwnDoorRounds = false;
}

public void OnPluginEnd()
{
    delete g_hController;
    for (int client = 1; client <= MaxClients; client++)
    {
        delete g_hClientHudInit[client];
    }
    StopStandaloneDoors();
    FinishCountdown(true);
    CleanupPostMatch();
    RestoreMatchHud();
    delete g_HeldTimers;
    delete g_PausedStopwatches;
    delete g_QueuedSpawnClients;
    delete g_RoundTimers;
    delete g_MapSchemaIds;
}

public void OnClientConnected(int client)
{
    ResetClientHudState(client);
    g_bHasSpawned[client] = false;
    g_iPlayerVotes[client] = VOTE_UNDECIDED;
}

public void OnClientPutInServer(int client)
{
    QueueClientHudInit(client);
    if (g_PostMatchPhase == PostMatch_Voting || g_PostMatchPhase == PostMatch_Chosen)
    {
        GameRules_SetProp("m_ePlayerWantsRematch", VOTE_UNDECIDED, 4, client);
    }
}

public void OnClientPostAdminCheck(int client)
{
    QueueClientHudInit(client);
}

public void OnClientDisconnect(int client)
{
    ResetClientHudState(client);
    g_bHasSpawned[client] = false;
    g_iPlayerVotes[client] = VOTE_UNDECIDED;
}

void ResetClientHudState(int client)
{
    delete g_hClientHudInit[client];
    g_bHudInitSent[client] = false;
    g_bCountdownHudRefreshed[client] = false;
    g_flClientHudReadyAt[client] = 0.0;
    g_iHudRefreshClients[client] = 0;
    g_iClientSummaryRun[client] = 0;
}

public Action Timer_Controller(Handle timer)
{
    if (timer != g_hController)
    {
        return Plugin_Stop;
    }
    if (!g_bMapRunning)
    {
        g_hController = null;
        return Plugin_Stop;
    }
    TryStartAutomaticCountdown();
    TickCountdownHudRefresh();
    TickPostMatch();
    TickFinalMatchAudio();
    return Plugin_Continue;
}

public void ConVar_FeaturesChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!g_cvCountdownEnabled.BoolValue)
    {
        ClearAutomaticCountdownQueue();
    }
    if (!g_bMapRunning || !g_bConfigsReady)
    {
        return;
    }
    // Snapshot active sequences; client animations cannot reliably be recalled halfway through.
    PrepareMatchHud();
    for (int client = 1; client <= MaxClients; client++)
    {
        QueueClientHudInit(client);
    }
    ConfigureAutomaticPostMatch();
}

bool IsSupportedGameMode()
{
    return !GameRules_GetProp("m_bPlayingMannVsMachine")
        && (g_cvArenaMode == null || !g_cvArenaMode.BoolValue);
}

bool UsesMatchPresentation()
{
    return g_cvCountdownEnabled.BoolValue || g_cvDoorsEnabled.BoolValue || g_cvSummaryEnabled.BoolValue
        || g_CountdownPhase != Countdown_None || g_PostMatchPhase != PostMatch_None
        || g_hDoorStartTimer != null || g_hDoorTickTimer != null;
}

void PrepareMatchHud()
{
    if (!g_bMapRunning || !IsSupportedGameMode())
    {
        return;
    }
    if (!UsesMatchPresentation())
    {
        RestoreMatchHud();
        return;
    }
    if (!g_bOwnMatchGroup)
    {
        g_iOriginalMatchGroup = GameRules_GetProp("m_nMatchGroupType");
        g_bOwnMatchGroup = true;
    }
    if (GameRules_GetProp("m_nMatchGroupType") != MATCH_GROUP_CASUAL)
    {
        GameRules_SetProp("m_nMatchGroupType", MATCH_GROUP_CASUAL);
    }
}

void RestoreMatchHud()
{
    if (g_bMapRunning && g_bOwnMatchGroup
        && GameRules_GetProp("m_nMatchGroupType") == MATCH_GROUP_CASUAL)
    {
        GameRules_SetProp("m_nMatchGroupType", g_iOriginalMatchGroup);
    }
    g_bOwnMatchGroup = false;
}

void QueueClientHudInit(int client)
{
    if (!g_bMapRunning || !g_bConfigsReady || !IsClientInGame(client) || IsFakeClient(client)
        || !IsSupportedGameMode() || !UsesMatchPresentation()
        || g_bHudInitSent[client] || g_hClientHudInit[client] != null)
    {
        return;
    }
    g_hClientHudInit[client] = CreateTimer(HUD_INIT_DELAY, Timer_ClientHudInit,
        GetClientSerial(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ClientHudInit(Handle timer, any serial)
{
    int client = GetClientFromSerial(serial);
    if (client <= 0 || timer != g_hClientHudInit[client])
    {
        return Plugin_Stop;
    }
    g_hClientHudInit[client] = null;
    if (!g_bMapRunning || !IsClientInGame(client) || !UsesMatchPresentation())
    {
        return Plugin_Stop;
    }
    InitializeClientHud(client);
    ReplayClientMatchPresentation(client);
    return Plugin_Stop;
}

void InitializeClientHud(int client)
{
    if (!g_bMapRunning || !IsClientInGame(client) || IsFakeClient(client)
        || g_bHudInitSent[client] || !IsSupportedGameMode() || !UsesMatchPresentation())
    {
        return;
    }

    // One presentation handshake per client/map; this does not create a GC match.
    PrepareMatchHud();
    Event event = CreateEvent("client_beginconnect", true);
    if (event != null)
    {
        event.SetString("source", "matchmaking");
        event.FireToClient(client);
        event.Cancel();
        g_bHudInitSent[client] = true;
    }
}

void ReplayClientMatchPresentation(int client)
{
    if (g_PostMatchPhase == PostMatch_Voting || g_PostMatchPhase == PostMatch_Chosen)
    {
        ShowClientMatchSummary(client);
        return;
    }
    int remaining = RoundToCeil(g_flCountdownDeadline - GetGameTime());
    if (g_CountdownPhase == Countdown_Waiting && remaining > 0)
    {
        Event event = CreateEvent("teamplay_round_restart_seconds", true);
        if (event != null)
        {
            event.SetInt("seconds", remaining);
            event.FireToClient(client);
            event.Cancel();
        }
    }
    else if ((g_CountdownPhase == Countdown_Final && g_bCountdownUsesDoors && remaining > 0 && remaining <= 10)
        || g_hDoorTickTimer != null)
    {
        Event event = CreateEvent("restart_timer_time", true);
        if (event != null)
        {
            event.SetInt("time", g_CountdownPhase == Countdown_Final ? remaining : g_iDoorSecondsRemaining);
            event.FireToClient(client);
            event.Cancel();
        }
    }
}

/* ============================================================================
 *  COUNTDOWN / FIRST SPAWN TO MATCH START
 * ========================================================================== */

public Action Command_Countdown(int client, int args)
{
    if (args > 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_countdown [seconds|stop|status]");
        return Plugin_Handled;
    }
    float seconds = g_cvCountdownSeconds.FloatValue;
    if (args == 1)
    {
        char value[32];
        GetCmdArg(1, value, sizeof(value));
        if (StrEqual(value, "stop", false))
        {
            CancelCountdownCommand(client);
            return Plugin_Handled;
        }
        if (StrEqual(value, "status", false))
        {
            PrintCountdownStatus(client);
            return Plugin_Handled;
        }
        if (value[0] == '\0' || StringToFloatEx(value, seconds) != strlen(value)
            || !(seconds >= 15.0 && seconds <= 600.0))
        {
            ReplyToCommand(client, "[SM] Use 15-600 seconds, stop, or status.");
            return Plugin_Handled;
        }
    }
    char reason[192];
    if (!CanStartCountdown(false, reason, sizeof(reason)))
    {
        ReplyToCommand(client, "[SM] %s", reason);
        return Plugin_Handled;
    }
    ClearAutomaticCountdownQueue();
    StartCountdown(seconds);
    ReplyToCommand(client, "[SM] Countdown started: %.0fs. Respawn at 10; play at zero. Cancel: sm_countdown stop.", seconds);
    return Plugin_Handled;
}

void PrintCountdownStatus(int client)
{
    if (!g_bMapRunning)
    {
        ReplyToCommand(client, "[SM] No active map.");
        return;
    }
    static const char phases[][] = { "idle", "warmup", "respawning", "final ten seconds" };
    float remaining = g_CountdownPhase != Countdown_None ? g_flCountdownDeadline - GetGameTime() : 0.0;
    ReplyToCommand(client, "[SM] Casual %s | %s | %.1fs left | reductions=%d | held timers=%d",
        PLUGIN_VERSION, phases[view_as<int>(g_CountdownPhase)], remaining, g_iCountdownReductions, g_HeldTimers.Length);
    ReplyToCommand(client, "[SM] countdown=%d | start=%.0fs | doors=%d | summary=%d | music=%d | HUD refresh=%d",
        g_cvCountdownEnabled.BoolValue, g_cvCountdownSeconds.FloatValue, g_cvDoorsEnabled.BoolValue,
        g_cvSummaryEnabled.BoolValue, g_cvMusicEnabled.BoolValue, g_bCountdownHudRefresh);
}

void CancelCountdownCommand(int client)
{
    if (g_bAutoCountdownPending)
    {
        g_bAutoCountdownUsed = true;
        ClearAutomaticCountdownQueue();
        ReplyToCommand(client, "[SM] Queued automatic countdown cancelled for this map.");
        return;
    }
    if (g_CountdownPhase == Countdown_None)
    {
        ReplyToCommand(client, "[SM] No countdown is active.");
        return;
    }
    bool alreadyRespawned = g_bRoundRestarted;
    FinishCountdown(true);
    if (alreadyRespawned)
    {
        ReplyToCommand(client, "[SM] Final countdown cancelled; the already-reset round and its timers were released.");
    }
    else
    {
        ReplyToCommand(client, "[SM] Countdown cancelled; saved settings restored.");
    }
    return;
}

void Frame_TryAutomaticCountdown(any serial)
{
    if (serial == g_iMapSerial)
    {
        TryStartAutomaticCountdown();
    }
}

void TryStartAutomaticCountdown()
{
    if (!g_bMapRunning || !g_bConfigsReady || !g_bAutoCountdownPending)
    {
        return;
    }
    if (!g_cvCountdownEnabled.BoolValue || g_bAutoCountdownUsed
        || g_PostMatchPhase != PostMatch_None || !IsSupportedGameMode())
    {
        ClearAutomaticCountdownQueue();
        return;
    }
    if (GameRules_GetRoundState() == RoundState_GameOver)
    {
        g_bAutoCountdownUsed = true;
        ClearAutomaticCountdownQueue();
        return;
    }
    for (int i = g_QueuedSpawnClients.Length - 1; i >= 0; i--)
    {
        if (GetClientFromSerial(g_QueuedSpawnClients.Get(i)) <= 0)
        {
            g_QueuedSpawnClients.Erase(i);
        }
    }
    if (g_QueuedSpawnClients.Length == 0)
    {
        ClearAutomaticCountdownQueue();
        return;
    }
    char reason[192];
    if (!CanStartCountdown(true, reason, sizeof(reason)))
    {
        return;
    }
    float seconds = g_cvCountdownSeconds.FloatValue;
    StartCountdown(seconds);
    DebugChatAll("[SM] First player spawned. Casual countdown: %.0f seconds.", seconds);
    for (int i = 1; i < g_QueuedSpawnClients.Length; i++)
    {
        ReduceCountdownForSpawn();
    }
    ClearAutomaticCountdownQueue();
}

void ClearAutomaticCountdownQueue()
{
    g_bAutoCountdownPending = false;
    g_QueuedSpawnClients.Clear();
}

bool CanStartCountdown(bool automatic, char[] reason, int maxlen)
{
    if (!g_cvCountdownEnabled.BoolValue)
    {
        strcopy(reason, maxlen, "Countdown is disabled (sm_casual_countdown 0).");
        return false;
    }
    if (!g_bMapRunning || !g_bConfigsReady)
    {
        strcopy(reason, maxlen, "Wait for the map and server configs to finish loading.");
        return false;
    }
    if (g_CountdownPhase != Countdown_None || g_PostMatchPhase != PostMatch_None)
    {
        strcopy(reason, maxlen, "A countdown or map-end sequence is already active.");
        return false;
    }
    if (!IsSupportedGameMode())
    {
        strcopy(reason, maxlen, "Use a normal PvP map, outside MvM/Arena.");
        return false;
    }
    RoundState state = GameRules_GetRoundState();

    if (state != RoundState_RoundRunning && !(automatic && state == RoundState_Preround))
    {
        strcopy(reason, maxlen, "Waiting for TF2 to enter the initial pre-round or a running round.");
        return false;
    }
    if (GameRules_GetPropFloat("m_flRestartRoundTime") > GetGameTime() || HasPendingRestartRequest())
    {
        strcopy(reason, maxlen, "Another restart/waiting-for-players request is pending. Let it finish first.");
        return false;
    }
    return true;
}

void StartCountdown(float seconds)
{
    StopStandaloneDoors();
    g_iSavedTournament = g_cvTournament.IntValue;
    g_iSavedReadyMode = g_cvReadyMode.IntValue;
    g_iSavedStopwatchCvar = g_cvStopwatch.IntValue;
    g_iSavedStopwatchFlag = GameRules_GetProp("m_bStopWatch");
    g_iSavedWaiting = GameRules_GetProp("m_bInWaitingForPlayers");
    g_iSavedAwaitingReady = GameRules_GetProp("m_bAwaitingReadyRestart");
    g_iSavedRoundsPlayed = GameRules_GetProp("m_nRoundsPlayed");
    g_flSavedCountdownTime = GameRules_GetPropFloat("m_flCountdownTime");
    g_bRoundRestarted = false;
    g_bHoldingPreRound = false;
    g_bCountdownUsesDoors = g_cvDoorsEnabled.BoolValue;
    g_flNextHudRefreshAt = 0.0;
    for (int client = 1; client <= MaxClients; client++)
    {
        g_bCountdownHudRefreshed[client] = false;
        g_flClientHudReadyAt[client] = 0.0;
        g_iHudRefreshClients[client] = 0;
    }
    g_iCountdownReductions = 0;
    g_HeldTimers.Clear();
    g_PausedStopwatches.Clear();
    g_iCountdownSerial++;
    g_CountdownPhase = Countdown_Waiting;

    g_bAutoCountdownUsed = true;
    g_bAutoCountdownPending = false;
    PrepareMatchHud();
    for (int target = 1; target <= MaxClients; target++)
    {
        InitializeClientHud(target);
    }

    PauseExistingStopwatches();
    DisableStopwatch(false);
    g_cvTournament.SetInt(1);
    g_cvReadyMode.SetInt(1);
    HoldNativeWaitingTimer();
    GameRules_SetProp("m_bInWaitingForPlayers", 1);
    GameRules_SetProp("m_bAwaitingReadyRestart", 0);
    // Nonzero selects the client's no-door countdown path ONLY during protected pre-match.
    // Restore zero before leaving pre-match so mp_maxrounds never sees a fabricated round.
    GameRules_SetProp("m_nRoundsPlayed", g_bCountdownUsesDoors ? 0 : 1);
    g_flCountdownDeadline = GetGameTime() + seconds;
    g_flOwnedRestartDeadline = g_flCountdownDeadline;
    g_flNextCountdownMonitorAt = 0.0;
    GameRules_SetPropFloat("m_flRestartRoundTime", g_flOwnedRestartDeadline);

    Event event = CreateEvent("teamplay_round_restart_seconds");
    if (event != null)
    {
        event.SetInt("seconds", RoundToCeil(seconds));
        event.Fire();
    }
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    int team = event.GetInt("team");
    int playerClass = event.GetInt("class");
    if (!g_bMapRunning || client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client)
        || (team != 2 && team != 3) || playerClass < 1 || playerClass > 9)
    {
        return;
    }

    bool firstSpawn = !g_bHasSpawned[client];
    g_bHasSpawned[client] = true;
    QueueClientHudInit(client);
    if (!firstSpawn)
    {
        return;
    }
    if (g_CountdownPhase == Countdown_Waiting)
    {
        ReduceCountdownForSpawn();
    }
    else if (g_cvCountdownEnabled.BoolValue && !g_bAutoCountdownUsed
        && g_CountdownPhase == Countdown_None && g_PostMatchPhase == PostMatch_None
        && IsSupportedGameMode())
    {
        g_QueuedSpawnClients.Push(GetClientSerial(client));
        if (!g_bAutoCountdownPending)
        {
            g_bAutoCountdownPending = true;
            RequestFrame(Frame_TryAutomaticCountdown, g_iMapSerial);
        }
    }
}

float ReducedCountdownDeadline(float deadline, float now)
{
    float remaining = deadline - now;
    if (remaining <= SPAWN_REDUCTION_FLOOR)
    {
        return deadline;
    }
    float shortened = remaining - SPAWN_REDUCTION_SECONDS;
    if (shortened < SPAWN_REDUCTION_FLOOR)
    {
        shortened = SPAWN_REDUCTION_FLOOR;
    }
    return now + shortened;
}

void ReduceCountdownForSpawn()
{
    if (g_CountdownPhase != Countdown_Waiting)
    {
        return;
    }
    if (!WaitingStateMatches())
    {
        AbortCountdown("Waiting state changed before a player's countdown reduction.");
        return;
    }
    float now = GetGameTime();
    float oldDeadline = g_flCountdownDeadline;
    float deadline = ReducedCountdownDeadline(oldDeadline, now);
    if (deadline >= oldDeadline)
    {
        return;
    }
    g_flCountdownDeadline = deadline;
    g_flOwnedRestartDeadline = deadline;
    if (!g_bCountdownHudRefresh)
    {
        GameRules_SetPropFloat("m_flRestartRoundTime", deadline);
    }
    g_iCountdownReductions++;
}

public void OnGameFrame()
{
    if (!g_bMapRunning)
    {
        return;
    }
    if (g_CountdownPhase == Countdown_None)
    {
        return;
    }

    if (GameRules_GetRoundState() == RoundState_GameOver)
    {
        g_bRoundRestarted = true;
        FinishCountdown(true);
        return;
    }
    float now = GetGameTime();
    if (g_CountdownPhase == Countdown_Waiting)
    {
        if (now >= g_flNextCountdownMonitorAt)
        {
            g_flNextCountdownMonitorAt = now + 0.25;
            if (!WaitingStateMatches())
            {
                AbortCountdown("Waiting state or restart deadline changed externally.");
                return;
            }
            DisableStopwatch(false);
        }
        if (now >= g_flCountdownDeadline - FINAL_COUNTDOWN_SECONDS)
        {
            if (!WaitingStateMatches())
            {
                AbortCountdown("Restart deadline changed before the final countdown.");
                return;
            }
            BeginRoundReset();
        }
    }
    else if (g_CountdownPhase == Countdown_RestartPending)
    {
        if (now > g_flRestartRequestedAt + 3.0)
        {
            AbortCountdown("TF2 did not report the requested round reset.");
        }
    }
    else if (g_CountdownPhase == Countdown_Final)
    {
        if (now >= g_flCountdownDeadline)
        {
            FinishCountdown(false);
            DebugChatAll("[SM] Match started. Round/setup timers re-enabled; stopwatch disabled.");
            return;
        }
        HoldMapTimers();
    }
}

bool WaitingStateMatches()
{
    float expected = g_bCountdownHudRefresh ? -1.0 : g_flOwnedRestartDeadline;
    return g_cvTournament.BoolValue && g_cvReadyMode.BoolValue
        && GameRules_GetProp("m_bInWaitingForPlayers") != 0
        && GameRules_GetProp("m_bAwaitingReadyRestart") == 0
        && FloatAbs(GameRules_GetPropFloat("m_flRestartRoundTime") - expected) <= 0.5;
}

void BeginRoundReset()
{
    // Native restart consumes the waiting state and performs the only respawn.
    CancelCountdownHudRefresh();
    g_CountdownPhase = Countdown_RestartPending;
    g_flRestartRequestedAt = GetGameTime();

    GameRules_SetProp("m_nRoundsPlayed", 0);
    GameRules_SetPropFloat("m_flCountdownTime", g_bCountdownUsesDoors ? g_flCountdownDeadline : -1.0);
    DisableStopwatch(false);

    g_cvReadyMode.SetInt(0);
    g_cvTournament.SetInt(0);
    g_flOwnedRestartDeadline = g_flRestartRequestedAt;
    GameRules_SetPropFloat("m_flRestartRoundTime", g_flOwnedRestartDeadline);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    StopStandaloneDoors(false);
    if (g_PostMatchPhase == PostMatch_None)
    {
        g_bSummaryTransition = false;
        ResetFinalMatchAudio();
    }
    if (g_CountdownPhase == Countdown_None)
    {
        return;
    }
    if (g_CountdownPhase != Countdown_RestartPending)
    {
        g_bRoundRestarted = true;
        AbortCountdown("An unexpected round start interrupted the countdown.");
        return;
    }

    g_bRoundRestarted = true;
    g_CountdownPhase = Countdown_Final;
    GameRules_SetProp("m_nRoundsPlayed", 0);
    DisableStopwatch(true);
    HoldMapTimers();

    RequestFrame(Frame_HoldFinalCountdown, g_iCountdownSerial);
}

void Frame_HoldFinalCountdown(any serial)
{
    if (!g_bMapRunning || g_CountdownPhase != Countdown_Final || serial != g_iCountdownSerial)
    {
        return;
    }
    if (GameRules_GetRoundState() != RoundState_Preround)
    {
        AbortCountdown("TF2 did not enter the expected pre-round state after respawning.");
        return;
    }

    // Run after State_Enter_PREROUND has assigned its own transition time.
    GameRules_SetPropFloat("m_flStateTransitionTime", g_flCountdownDeadline);
    GameRules_SetPropFloat("m_flCountdownTime", g_bCountdownUsesDoors ? g_flCountdownDeadline : -1.0);
    g_bHoldingPreRound = true;
    DisableStopwatch(true);
    HoldMapTimers();
}

bool HasPendingRestartRequest()
{
    for (int i = 0; i < sizeof(g_cvRestartRequests); i++)
    {
        if (g_cvRestartRequests[i] != null && g_cvRestartRequests[i].IntValue != 0)
        {
            return true;
        }
    }
    return false;
}

void FinishCountdown(bool cancelled)
{
    CancelCountdownHudRefresh();
    if (g_CountdownPhase == Countdown_None)
    {
        return;
    }

    bool restoreOriginal = cancelled && !g_bRoundRestarted;
    g_CountdownPhase = Countdown_None;
    g_iCountdownSerial++;

    if (g_bMapRunning)
    {
        if (FloatAbs(GameRules_GetPropFloat("m_flRestartRoundTime") - g_flOwnedRestartDeadline) <= 0.5)
        {
            GameRules_SetPropFloat("m_flRestartRoundTime", -1.0);
        }
        if (FloatAbs(GameRules_GetPropFloat("m_flCountdownTime") - g_flCountdownDeadline) <= 0.5)
        {
            GameRules_SetPropFloat("m_flCountdownTime", restoreOriginal ? g_flSavedCountdownTime : -1.0);
        }
        if (restoreOriginal)
        {
            GameRules_SetProp("m_bInWaitingForPlayers", g_iSavedWaiting);
            GameRules_SetProp("m_bAwaitingReadyRestart", g_iSavedAwaitingReady);
            GameRules_SetProp("m_nRoundsPlayed", g_iSavedRoundsPlayed);
            GameRules_SetProp("m_bStopWatch", g_iSavedStopwatchFlag);
        }
        if (g_bHoldingPreRound && GameRules_GetRoundState() == RoundState_Preround
            && FloatAbs(GameRules_GetPropFloat("m_flStateTransitionTime") - g_flCountdownDeadline) <= 0.5)
        {
            GameRules_SetPropFloat("m_flStateTransitionTime", GetGameTime() - 0.01);
        }

        PrepareMatchHud();
    }
    g_bHoldingPreRound = false;

    // Restore stopwatch only when cancelling BEFORE the native reset.
    g_cvStopwatch.SetInt(restoreOriginal ? g_iSavedStopwatchCvar : 0);
    if (g_bMapRunning && !restoreOriginal)
    {
        DisableStopwatch(true);
    }
    g_cvReadyMode.SetInt(g_iSavedReadyMode);
    g_cvTournament.SetInt(g_iSavedTournament);
    ReleaseMapTimers();
    if (restoreOriginal)
    {
        RestorePausedStopwatches();
    }
    else
    {
        g_PausedStopwatches.Clear();
    }
}

void AbortCountdown(const char[] reason)
{
    DebugPrint("[SM] Countdown interrupted: %s", reason);
    if (g_bMapRunning && g_cvDebug.BoolValue)
    {
        PrintCountdownStatus(0);
    }
    FinishCountdown(true);
    DebugChatAll("[SM] Countdown interrupted. Held timers were released.");
}

bool CanRefreshClientCountdownHud(int client)
{
    return IsClientInGame(client) && !IsFakeClient(client) && g_bHudInitSent[client]
        && IsPlayerAlive(client) && GetClientTeam(client) >= 2
        && GetEntProp(client, Prop_Send, "m_iClass") > 0;
}

void TickCountdownHudRefresh()
{
    if (g_CountdownPhase != Countdown_Waiting || g_PostMatchPhase != PostMatch_None
        || g_bCountdownHudRefresh || g_flCountdownDeadline - GetGameTime() <= FINAL_COUNTDOWN_SECONDS + 2.0)
    {
        return;
    }
    float now = GetGameTime();
    bool due = false;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_bCountdownHudRefreshed[client] || !CanRefreshClientCountdownHud(client))
        {
            g_flClientHudReadyAt[client] = 0.0;
            continue;
        }
        if (g_flClientHudReadyAt[client] == 0.0)
        {
            g_flClientHudReadyAt[client] = now + HUD_REFRESH_SETTLE;
        }
        if (g_flClientHudReadyAt[client] <= now)
        {
            due = true;
        }
    }
    if (!due || now < g_flNextHudRefreshAt || !WaitingStateMatches() || HasPendingRestartRequest()
        || GameRules_GetPropFloat("m_flCountdownTime") > now)
    {
        return;
    }
    g_hCountdownHudRefresh = CreateTimer(HUD_REFRESH_SECONDS, Timer_RestoreCountdownHud,
        g_iCountdownSerial, TIMER_FLAG_NO_MAPCHANGE);
    if (g_hCountdownHudRefresh == null)
    {
        return;
    }
    for (int client = 1; client <= MaxClients; client++)
    {
        g_iHudRefreshClients[client] = g_flClientHudReadyAt[client] > 0.0
            && g_flClientHudReadyAt[client] <= now && CanRefreshClientCountdownHud(client)
            ? GetClientSerial(client) : 0;
    }
    g_bCountdownHudRefresh = true;
    g_flNextHudRefreshAt = now + HUD_REFRESH_COOLDOWN;
    // Pulse the native visibility flag; the logical deadline keeps advancing.
    // Negative time cannot trigger TF2's positive-expired-time restart path.
    GameRules_SetPropFloat("m_flRestartRoundTime", -1.0);
}

public Action Timer_RestoreCountdownHud(Handle timer, any serial)
{
    if (timer != g_hCountdownHudRefresh)
    {
        return Plugin_Stop;
    }
    g_hCountdownHudRefresh = null;
    if (!g_bMapRunning || serial != g_iCountdownSerial
        || g_CountdownPhase != Countdown_Waiting || !g_bCountdownHudRefresh)
    {
        g_bCountdownHudRefresh = false;
        return Plugin_Stop;
    }
    if (!WaitingStateMatches() || HasPendingRestartRequest()
        || FloatAbs(GameRules_GetPropFloat("m_flRestartRoundTime") + 1.0) > 0.01)
    {
        AbortCountdown("Native waiting/restart state changed during the countdown HUD refresh.");
        return Plugin_Stop;
    }

    // Restore the latest deadline, including spawns during the pulse; never add time.
    GameRules_SetPropFloat("m_flRestartRoundTime", g_flOwnedRestartDeadline);
    g_bCountdownHudRefresh = false;
    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_iHudRefreshClients[client] != 0 && CanRefreshClientCountdownHud(client)
            && GetClientSerial(client) == g_iHudRefreshClients[client])
        {
            g_bCountdownHudRefreshed[client] = true;
        }
        g_iHudRefreshClients[client] = 0;
    }
    return Plugin_Stop;
}

void CancelCountdownHudRefresh()
{
    delete g_hCountdownHudRefresh;
    g_bCountdownHudRefresh = false;
    for (int client = 1; client <= MaxClients; client++)
    {
        g_iHudRefreshClients[client] = 0;
    }
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (g_RoundTimers != null && StrEqual(classname, "team_round_timer"))
    {
        SDKHook(entity, SDKHook_SpawnPost, RoundTimer_SpawnPost);
    }
}

public void RoundTimer_SpawnPost(int entity)
{
    TrackRoundTimer(entity);
    if (g_CountdownPhase == Countdown_Final && g_bMapRunning)
    {
        HoldRoundTimer(entity);
    }
}

void TrackRoundTimer(int entity)
{
    int ref = EntIndexToEntRef(entity);
    for (int i = g_RoundTimers.Length - 1; i >= 0; i--)
    {
        if (GetTrackedRoundTimer(i) != -1 && g_RoundTimers.Get(i) == ref)
        {
            return;
        }
    }
    g_RoundTimers.Push(ref);
}

void CacheRoundTimers()
{
    g_RoundTimers.Clear();
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "team_round_timer")) != -1)
    {
        TrackRoundTimer(entity);
    }
}

int GetTrackedRoundTimer(int index)
{
    int entity = EntRefToEntIndex(g_RoundTimers.Get(index));
    if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity))
    {
        g_RoundTimers.Erase(index);
        return -1;
    }
    return entity;
}

void HoldNativeWaitingTimer()
{
    for (int i = g_RoundTimers.Length - 1; i >= 0; i--)
    {
        int entity = GetTrackedRoundTimer(i);
        if (entity == -1)
        {
            continue;
        }
        char name[64];
        GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
        if (StrEqual(name, "zz_teamplay_waiting_timer"))
        {
            HoldRoundTimer(entity);
        }
    }
}

void HoldMapTimers()
{
    for (int i = g_RoundTimers.Length - 1; i >= 0; i--)
    {
        int entity = GetTrackedRoundTimer(i);
        if (entity != -1)
        {
            HoldRoundTimer(entity);
        }
    }
}

void HoldRoundTimer(int entity)
{
    if (!IsValidEntity(entity) || GetEntProp(entity, Prop_Send, "m_bStopWatchTimer")
        || GetEntProp(entity, Prop_Send, "m_bIsDisabled"))
    {
        return;
    }

    bool running = !GetEntProp(entity, Prop_Send, "m_bTimerPaused");
    int ref = EntIndexToEntRef(entity);
    int index = g_HeldTimers.FindValue(ref, TIMER_REF);
    int record[TIMER_RECORD_SIZE];
    if (index == -1)
    {
        record[TIMER_REF] = ref;
    }
    else
    {
        g_HeldTimers.GetArray(index, record, sizeof(record));
    }

    // Disable freezes and hides the timer; originally disabled timers are never owned.
    if (!AcceptEntityInput(entity, "Disable"))
    {
        return;
    }
    if (running)
    {
        record[TIMER_WAS_RUNNING] = 1;
    }
    if (index == -1)
    {
        g_HeldTimers.PushArray(record, sizeof(record));
    }
    else
    {
        g_HeldTimers.SetArray(index, record, sizeof(record));
    }
}

void ReleaseMapTimers()
{
    if (g_bMapRunning)
    {
        int record[TIMER_RECORD_SIZE];
        for (int i = 0; i < g_HeldTimers.Length; i++)
        {
            g_HeldTimers.GetArray(i, record, sizeof(record));
            int entity = EntRefToEntIndex(record[TIMER_REF]);
            if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity)
                || !GetEntProp(entity, Prop_Send, "m_bIsDisabled"))
            {
                continue;
            }
            AcceptEntityInput(entity, "Enable");

            // Enable resumes automatically; preserve a timer that was already paused.
            if (!record[TIMER_WAS_RUNNING])
            {
                AcceptEntityInput(entity, "Pause");
            }
        }
    }
    g_HeldTimers.Clear();
}

void PauseExistingStopwatches()
{
    for (int i = g_RoundTimers.Length - 1; i >= 0; i--)
    {
        int entity = GetTrackedRoundTimer(i);
        if (entity != -1 && GetEntProp(entity, Prop_Send, "m_bStopWatchTimer")
            && !GetEntProp(entity, Prop_Send, "m_bIsDisabled")
            && !GetEntProp(entity, Prop_Send, "m_bTimerPaused"))
        {
            if (AcceptEntityInput(entity, "Pause"))
            {
                g_PausedStopwatches.Push(EntIndexToEntRef(entity));
            }
        }
    }
}

void DisableStopwatch(bool removeTimers)
{
    if (g_cvStopwatch.IntValue != 0)
    {
        g_cvStopwatch.SetInt(0);
    }
    if (GameRules_GetProp("m_bStopWatch") != 0)
    {
        GameRules_SetProp("m_bStopWatch", 0);
    }
    if (!removeTimers)
    {
        return;
    }

    for (int i = g_RoundTimers.Length - 1; i >= 0; i--)
    {
        int entity = GetTrackedRoundTimer(i);
        if (entity != -1 && GetEntProp(entity, Prop_Send, "m_bStopWatchTimer"))
        {
            AcceptEntityInput(entity, "Disable");
            AcceptEntityInput(entity, "Kill");
        }
    }
}

void RestorePausedStopwatches()
{
    if (g_bMapRunning)
    {
        for (int i = 0; i < g_PausedStopwatches.Length; i++)
        {
            int entity = EntRefToEntIndex(g_PausedStopwatches.Get(i));
            if (entity != INVALID_ENT_REFERENCE && IsValidEntity(entity)
                && !GetEntProp(entity, Prop_Send, "m_bIsDisabled"))
            {
                AcceptEntityInput(entity, "Resume");
            }
        }
    }
    g_PausedStopwatches.Clear();
}

/* ============================================================================
 *  DOORS / PRE-MATCH PRESENTATION
 * ========================================================================== */

public Action Command_Doors(int client, int args)
{
    if (args != 0 || !g_cvDoorsEnabled.BoolValue)
    {
        ReplyToCommand(client, "[SM] Usage: sm_doors. Requires sm_casual_doors 1.");
        return Plugin_Handled;
    }
    if (g_PostMatchPhase != PostMatch_None)
    {
        ReplyToCommand(client, "[SM] A map-end sequence is active.");
        return Plugin_Handled;
    }
    if (g_CountdownPhase != Countdown_None)
    {
        ReplyToCommand(client, "[SM] Cancel the countdown with sm_countdown stop first.");
        return Plugin_Handled;
    }
    if (!g_bMapRunning || !g_bConfigsReady || GameRules_GetRoundState() == RoundState_GameOver)
    {
        ReplyToCommand(client, "[SM] Wait for a loaded map outside intermission.");
        return Plugin_Handled;
    }
    if (!IsSupportedGameMode())
    {
        ReplyToCommand(client, "[SM] Use a normal PvP map outside MvM/Arena.");
        return Plugin_Handled;
    }
    StopStandaloneDoors();
    PrepareMatchHud();
    for (int target = 1; target <= MaxClients; target++)
    {
        InitializeClientHud(target);
    }
    g_iDoorSavedRounds = GameRules_GetProp("m_nRoundsPlayed");
    g_bOwnDoorRounds = true;
    GameRules_SetProp("m_nRoundsPlayed", 0);
    g_hDoorStartTimer = CreateTimer(HUD_INIT_DELAY, Timer_StartDoors, 0, TIMER_FLAG_NO_MAPCHANGE);
    if (g_hDoorStartTimer == null)
    {
        StopStandaloneDoors();
        ReplyToCommand(client, "[SM] Could not schedule the doors.");
        return Plugin_Handled;
    }
    ReplyToCommand(client, "[SM] Doors queued after %.1fs of HUD initialization.", HUD_INIT_DELAY);
    return Plugin_Handled;
}

void StopStandaloneDoors(bool restoreRounds = true)
{
    delete g_hDoorStartTimer;
    delete g_hDoorTickTimer;
    if (restoreRounds && g_bMapRunning && g_bOwnDoorRounds
        && GameRules_GetProp("m_nRoundsPlayed") == 0)
    {
        GameRules_SetProp("m_nRoundsPlayed", g_iDoorSavedRounds);
    }
    g_bOwnDoorRounds = false;
    g_iDoorSecondsRemaining = 0;
}

public Action Timer_StartDoors(Handle timer)
{
    if (timer != g_hDoorStartTimer)
    {
        return Plugin_Stop;
    }
    g_hDoorStartTimer = null;
    if (!g_bMapRunning || g_CountdownPhase != Countdown_None)
    {
        return Plugin_Stop;
    }
    g_iDoorSecondsRemaining = 10;
    g_hDoorTickTimer = CreateTimer(1.0, Timer_DoorTick, 0,
        TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    if (g_hDoorTickTimer == null)
    {
        StopStandaloneDoors();
        return Plugin_Stop;
    }
    FireCountdownEvent(g_iDoorSecondsRemaining);
    return Plugin_Stop;
}

public Action Timer_DoorTick(Handle timer)
{
    if (timer != g_hDoorTickTimer)
    {
        return Plugin_Stop;
    }
    if (!g_bMapRunning || g_CountdownPhase != Countdown_None)
    {
        g_hDoorTickTimer = null;
        return Plugin_Stop;
    }
    FireCountdownEvent(--g_iDoorSecondsRemaining);
    if (g_iDoorSecondsRemaining > 0)
    {
        return Plugin_Continue;
    }
    g_hDoorTickTimer = null;
    StopStandaloneDoors();
    PrepareMatchHud();
    return Plugin_Stop;
}

void FireCountdownEvent(int seconds)
{
    Event event = CreateEvent("restart_timer_time");
    if (event != null)
    {
        event.SetInt("time", seconds);
        event.Fire();
    }
}

/* ============================================================================
 *  MATCH SUMMARY / NEXT-MAP VOTING
 * ========================================================================== */

public Action Event_GameOver(Event event, const char[] name, bool dontBroadcast)
{
    if (g_bMapRunning && g_bPostMatchArmed)
    {
        g_bSummaryTransition = true;
        g_flSummaryTransitionUntil = GetGameTime() + 2.0;
        RequestFrame(Frame_CheckPostMatch, g_iMapSerial);
    }
    return Plugin_Continue;
}

void Frame_CheckPostMatch(any serial)
{
    if (serial == g_iMapSerial && g_bMapRunning)
    {
        TickPostMatch();
    }
}

public void ConVar_PostMatchSettingsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    ConfigureAutomaticPostMatch();
}

void ConfigureAutomaticPostMatch()
{
    if (!g_bMapRunning || !g_bConfigsReady || g_PostMatchPhase != PostMatch_None)
    {
        return;
    }
    g_bPostMatchArmed = false;
    if (!g_cvSummaryEnabled.BoolValue)
    {
        RestoreVoteIntermission();
        return;
    }

    if (GameRules_GetRoundState() == RoundState_GameOver)
    {
        return;
    }
    char reason[192];
    if (!PostMatchAvailable(reason, sizeof(reason)) || !LoadMapVoteSchema(reason, sizeof(reason))
        || !BuildDefaultVoteMaps(reason, sizeof(reason)))
    {
        RestoreVoteIntermission();
        DebugPrint("[SM] Automatic Casual map vote not armed: %s", reason);
        return;
    }
    ReserveVoteIntermission();
    g_bPostMatchArmed = true;
}

public Action Command_EndMap(int client, int args)
{
    if (args == 1)
    {
        char option[16];
        GetCmdArg(1, option, sizeof(option));
        if (StrEqual(option, "status", false))
        {
            PrintVoteStatus(client);
            return Plugin_Handled;
        }
    }
    if (!g_bMapRunning || !g_bConfigsReady)
    {
        ReplyToCommand(client, "[SM] Wait for the map and configs to finish loading.");
        return Plugin_Handled;
    }
    if (!g_cvSummaryEnabled.BoolValue)
    {
        ReplyToCommand(client, "[SM] Match summary is disabled (sm_casual_summary 0).");
        return Plugin_Handled;
    }
    if (args != 0 && args != VOTE_OPTION_COUNT)
    {
        ReplyToCommand(client, "[SM] Usage: sm_endmap [map1 map2 map3] - ends this map and votes on the next.");
        return Plugin_Handled;
    }
    if (g_PostMatchPhase != PostMatch_None)
    {
        ReplyToCommand(client, "[SM] A map-end sequence is already active. Use sm_endmap status.");
        return Plugin_Handled;
    }
    char reason[192];
    if (!PostMatchAvailable(reason, sizeof(reason)) || !LoadMapVoteSchema(reason, sizeof(reason)))
    {
        ReplyToCommand(client, "[SM] %s", reason);
        return Plugin_Handled;
    }
    if (GameRules_GetRoundState() == RoundState_GameOver)
    {
        ReplyToCommand(client, "[SM] This map is already ending. Run the command before intermission.");
        return Plugin_Handled;
    }
    if (args == 0)
    {
        if (!BuildDefaultVoteMaps(reason, sizeof(reason)))
        {
            ReplyToCommand(client, "[SM] %s", reason);
            return Plugin_Handled;
        }
    }
    else
    {
        g_iVoteOptions = 0;
        for (int i = 1; i <= VOTE_OPTION_COUNT; i++)
        {
            char map[CASUAL_MAP_NAME_LENGTH];
            GetCmdArg(i, map, sizeof(map));
            if (!AddVoteMap(map, reason, sizeof(reason)))
            {
                ReplyToCommand(client, "[SM] %s Map unchanged.", reason);
                return Plugin_Handled;
            }
        }
    }

    g_bAutoCountdownUsed = true;
    ClearAutomaticCountdownQueue();
    if (g_CountdownPhase != Countdown_None)
    {
        FinishCountdown(true);
        ReplyToCommand(client, "[SM] Active countdown cancelled for the requested map ending.");
    }
    StopStandaloneDoors();
    PrepareMatchHud();
    for (int target = 1; target <= MaxClients; target++)
    {
        InitializeClientHud(target);
    }
    ReserveVoteIntermission();
    g_PostMatchPhase = PostMatch_Queued;
    g_bSummaryTransition = true;
    g_bPostMatchAttempted = true;
    g_iEndMapRequesterSerial = client > 0 ? GetClientSerial(client) : 0;
    g_hEndMapTimer = CreateTimer(HUD_INIT_DELAY, Timer_EndMap, 0, TIMER_FLAG_NO_MAPCHANGE);
    if (g_hEndMapTimer == null)
    {
        CleanupPostMatch();
        ConfigureAutomaticPostMatch();
        ReplyToCommand(client, "[SM] Could not schedule the map ending.");
        return Plugin_Handled;
    }
    ReplyToCommand(client, "[SM] Ending this match, then voting: %s / %s / %s. Intermission loads the winner; a same-map win reloads the map, not the server process.",
        g_szVoteMaps[0], g_szVoteMaps[1], g_szVoteMaps[2]);
    return Plugin_Handled;
}

void PrintVoteStatus(int client)
{
    if (!g_bMapRunning)
    {
        ReplyToCommand(client, "[SM] No active map.");
        return;
    }
    ReplyToCommand(client, "[SM] TF2 Community Casual v%s | countdown_phase=%d | postmatch_phase=%d | map_loaded=%d",
        PLUGIN_VERSION, view_as<int>(g_CountdownPhase), view_as<int>(g_PostMatchPhase), g_bMapRunning);
    char reason[192];
    bool available = PostMatchAvailable(reason, sizeof(reason));
    if (!available)
    {
        ReplyToCommand(client, "[SM] Native vote check failed: %s", reason);
    }
    if (g_bMapRunning)
    {
        if (LoadMapVoteSchema(reason, sizeof(reason)))
        {
            ReplyToCommand(client, "[SM] Item schema loaded: %d native map definitions.", g_MapSchemaIds.Size);
        }
        else
        {
            ReplyToCommand(client, "[SM] Map schema check failed: %s", reason);
        }
    }
    if (!available)
    {
        return;
    }
    int votes[VOTE_OPTION_COUNT];
    TallyPostMatchVotes(votes);
    ReplyToCommand(client, "[SM] postmatch_phase=%d | auto=%d | armed=%d | round_state=%d | native_vote_state=%d | summary=%d",
        view_as<int>(g_PostMatchPhase), g_cvSummaryEnabled.BoolValue, g_bPostMatchArmed,
        view_as<int>(GameRules_GetRoundState()), GameRules_GetProp("m_eRematchState"),
        GameRules_GetProp("m_bShowMatchSummary"));
    for (int i = 0; i < g_iVoteOptions; i++)
    {
        ReplyToCommand(client, "[SM] Choice %d: %s | schema_id=%d | votes=%d",
            i, g_szVoteMaps[i], g_iMapDefIds[i], votes[i]);
    }
    ReplyToCommand(client, "[SM] native_vote_seconds=%.1f | remaining=%.1f | mp_chattime=%d | winning_choice=%d",
        g_cvNativeVoteTime.FloatValue,
        g_PostMatchPhase == PostMatch_Voting ? g_flVoteDeadline - GetGameTime() : 0.0,
        g_cvChatTime.IntValue, g_iWinningMap);
    ReplyToCommand(client, "[SM] scoreboard_filter=%d | match_music=%d | final_result_known=%d | winning_team=%d | music_played=%d",
        g_msgVguiMenu != INVALID_MESSAGE_ID && GetUserMessageType() == UM_BitBuf,
        g_cvMusicEnabled.BoolValue, g_bFinalResultKnown, g_iFinalWinningTeam, g_bFinalMusicPlayed);
    return;
}

bool PostMatchAvailable(char[] reason, int maxlen)
{
    if (!g_bMapRunning || !IsSupportedGameMode())
    {
        strcopy(reason, maxlen, "Use a loaded normal PvP map, outside MvM/Arena.");
        return false;
    }
    if (g_cvNativeVoteTime == null)
    {
        strcopy(reason, maxlen, "Missing server convar: tf_mm_next_map_vote_time.");
        return false;
    }
    if (g_cvChatTime == null || g_cvNextLevel == null)
    {
        strcopy(reason, maxlen, "Missing server convar: mp_chattime or nextlevel.");
        return false;
    }
    if (g_cvNativeVoteTime.FloatValue < 5.0 || g_cvNativeVoteTime.FloatValue > 90.0)
    {
        strcopy(reason, maxlen, "Set tf_mm_next_map_vote_time between 5 and 90 seconds (Valve default: 15).");
        return false;
    }
    static const char props[][] =
    {
        "m_bShowMatchSummary", "m_eRematchState", "m_nNextMapVoteOptions", "m_ePlayerWantsRematch"
    };
    for (int i = 0; i < sizeof(props); i++)
    {
        if (FindSendPropInfo("CTFGameRulesProxy", props[i]) < 0)
        {
            Format(reason, maxlen, "Required native field is missing: %s", props[i]);
            return false;
        }
    }
    return true;
}

bool LoadMapVoteSchema(char[] reason, int maxlen)
{
    if (g_bSchemaLoaded)
    {
        return true;
    }
    g_MapSchemaIds.Clear();
    KeyValues schema = new KeyValues("items_game");

    if (!schema.ImportFromFile("scripts/items/items_game.txt"))
    {
        delete schema;
        strcopy(reason, maxlen, "Could not load scripts/items/items_game.txt through the game filesystem.");
        return false;
    }
    if (!schema.JumpToKey("master_maps_list"))
    {
        delete schema;
        strcopy(reason, maxlen, "items_game.txt loaded, but its master_maps_list section is missing.");
        return false;
    }
    if (!schema.GotoFirstSubKey())
    {
        delete schema;
        strcopy(reason, maxlen, "items_game.txt loaded, but its master_maps_list has no map entries.");
        return false;
    }
    do
    {
        char indexText[32], map[CASUAL_MAP_NAME_LENGTH];
        int defIndex;
        schema.GetSectionName(indexText, sizeof(indexText));
        schema.GetString("name", map, sizeof(map));
        if (map[0] != '\0' && StringToIntEx(indexText, defIndex) == strlen(indexText) && defIndex >= 0)
        {
            for (int i = 0; map[i] != '\0'; i++)
            {
                map[i] = CharToLower(map[i]);
            }
            g_MapSchemaIds.SetValue(map, defIndex);
        }
    }
    while (schema.GotoNextKey());
    delete schema;
    g_bSchemaLoaded = g_MapSchemaIds.Size > 0;
    if (!g_bSchemaLoaded)
    {
        strcopy(reason, maxlen, "The installed item schema contained no usable map definitions.");
    }
    return g_bSchemaLoaded;
}

bool AddVoteMap(const char[] requested, char[] reason, int maxlen)
{
    if (g_iVoteOptions >= VOTE_OPTION_COUNT)
    {
        strcopy(reason, maxlen, "All three map slots are already filled.");
        return false;
    }
    char map[CASUAL_MAP_NAME_LENGTH];
    strcopy(map, sizeof(map), requested);
    TrimString(map);
    for (int i = 0; map[i] != '\0'; i++)
    {
        map[i] = CharToLower(map[i]);
    }
    int defIndex;
    if (!IsMapValid(map))
    {
        Format(reason, maxlen, "Map '%s' is not installed or TF2 considers it invalid.", map);
        return false;
    }
    if (!g_MapSchemaIds.GetValue(map, defIndex))
    {
        Format(reason, maxlen, "Map '%s' has no native card in the server's item schema (%d entries).", map, g_MapSchemaIds.Size);
        return false;
    }
    for (int i = 0; i < g_iVoteOptions; i++)
    {
        if (StrEqual(map, g_szVoteMaps[i], false))
        {
            Format(reason, maxlen, "Map '%s' was specified more than once; use three distinct maps.", map);
            return false;
        }
    }
    strcopy(g_szVoteMaps[g_iVoteOptions], CASUAL_MAP_NAME_LENGTH, map);
    g_iMapDefIds[g_iVoteOptions] = defIndex;
    g_iVoteOptions++;
    return true;
}

bool BuildDefaultVoteMaps(char[] reason, int maxlen)
{
    g_iVoteOptions = 0;
    char map[CASUAL_MAP_NAME_LENGTH];
    GetCurrentMap(map, sizeof(map));
    AddVoteMap(map, reason, maxlen);

    int serial = -1;
    ArrayList maps = view_as<ArrayList>(ReadMapList(null, serial, "default"));
    if (maps != null)
    {
        for (int i = 0; i < maps.Length && g_iVoteOptions < VOTE_OPTION_COUNT; i++)
        {
            maps.GetString(i, map, sizeof(map));
            AddVoteMap(map, reason, maxlen);
        }
        delete maps;
    }
    if (g_iVoteOptions != VOTE_OPTION_COUNT)
    {
        strcopy(reason, maxlen, "Need three distinct installed schema maps in the map rotation, or specify three map names.");
        return false;
    }
    return true;
}

void ReserveVoteIntermission()
{
    int needed = RoundToCeil(g_cvNativeVoteTime.FloatValue + HUD_INIT_DELAY + 5.0);
    float current = g_cvChatTime.FloatValue;
    if (current >= float(needed))
    {
        return;
    }
    if (!g_bOwnChatTime || FloatAbs(current - float(g_iOwnedChatTime)) > 0.01)
    {
        g_flSavedChatTime = current;
    }
    g_iOwnedChatTime = needed;
    g_bOwnChatTime = true;

    // Reserve before GoToIntermission snapshots mp_chattime.
    g_cvChatTime.SetInt(needed);
}

void RestoreVoteIntermission()
{
    if (g_bOwnChatTime)
    {
        if (FloatAbs(g_cvChatTime.FloatValue - float(g_iOwnedChatTime)) <= 0.01)
        {
            g_cvChatTime.SetFloat(g_flSavedChatTime);
        }
        g_bOwnChatTime = false;
    }
}

public Action Timer_EndMap(Handle timer)
{
    if (timer != g_hEndMapTimer)
    {
        return Plugin_Stop;
    }
    g_hEndMapTimer = null;
    if (!g_bMapRunning || g_PostMatchPhase != PostMatch_Queued)
    {
        return Plugin_Stop;
    }
    int savedTournament = g_cvTournament.IntValue;
    int savedReadyMode = g_cvReadyMode.IntValue;
    g_cvTournament.SetInt(0);
    g_cvReadyMode.SetInt(0);
    if (GameRules_GetRoundState() != RoundState_GameOver)
    {
        int end = CreateEntityByName("game_end");
        if (end == -1)
        {
            ReportEndMapFailure("Could not create the game_end entity.");
            g_cvTournament.SetInt(savedTournament);
            g_cvReadyMode.SetInt(savedReadyMode);
            CleanupPostMatch();
            return Plugin_Stop;
        }
        bool spawned = DispatchSpawn(end);
        bool accepted = spawned && AcceptEntityInput(end, "EndGame");
        if (IsValidEntity(end))
        {
            RemoveEntity(end);
        }
        if (!accepted)
        {
            ReportEndMapFailure("Could not spawn game_end or send its EndGame input.");
            g_cvTournament.SetInt(savedTournament);
            g_cvReadyMode.SetInt(savedReadyMode);
            CleanupPostMatch();
            return Plugin_Stop;
        }
    }
    if (GameRules_GetRoundState() != RoundState_GameOver)
    {
        ReportEndMapFailure("TF2 did not enter intermission; Casual vote cancelled.");
        g_cvTournament.SetInt(savedTournament);
        g_cvReadyMode.SetInt(savedReadyMode);
        CleanupPostMatch();
        return Plugin_Stop;
    }
    BeginPostMatchVote();
    return Plugin_Stop;
}

void ReportEndMapFailure(const char[] reason)
{
    DebugPrint("[SM] Casual end-map failed: %s", reason);
    int client = g_iEndMapRequesterSerial > 0 ? GetClientFromSerial(g_iEndMapRequesterSerial) : 0;
    if (client > 0 && IsClientInGame(client))
    {
        PrintToChat(client, "[SM] Casual end-map failed: %s", reason);
    }
}

void TickPostMatch()
{
    if (g_PostMatchPhase == PostMatch_None && g_cvSummaryEnabled.BoolValue
        && g_bPostMatchArmed && !g_bPostMatchAttempted
        && GameRules_GetRoundState() == RoundState_GameOver)
    {
        g_bPostMatchAttempted = true;
        g_bAutoCountdownUsed = true;
        ClearAutomaticCountdownQueue();
        if (g_CountdownPhase != Countdown_None)
        {
            g_bRoundRestarted = true;
            FinishCountdown(true);
        }
        char reason[192];
        if (PostMatchAvailable(reason, sizeof(reason)) && BuildDefaultVoteMaps(reason, sizeof(reason)))
        {
            StopStandaloneDoors();
            BeginPostMatchVote();
        }
        else
        {
            DebugPrint("[SM] Casual map vote skipped: %s", reason);
            g_bPostMatchArmed = false;
            g_bSummaryTransition = false;
            ShowNormalIntermissionScoreboard();
        }
    }
    if (g_PostMatchPhase == PostMatch_Voting && GetGameTime() >= g_flVoteDeadline)
    {
        ResolvePostMatchVote();
    }
}

void BeginPostMatchVote()
{
    PrepareMatchHud();
    g_iVoteRunSerial++;
    g_PostMatchPhase = PostMatch_Voting;
    g_bSummaryTransition = true;
    g_iWinningMap = -1;
    g_flVoteDeadline = GetGameTime() + g_cvNativeVoteTime.FloatValue;
    for (int option = 0; option < VOTE_OPTION_COUNT; option++)
    {
        GameRules_SetProp("m_nNextMapVoteOptions", g_iMapDefIds[option], 4, option);
    }
    for (int client = 1; client <= MaxClients; client++)
    {
        g_iPlayerVotes[client] = VOTE_UNDECIDED;
        GameRules_SetProp("m_ePlayerWantsRematch", VOTE_UNDECIDED, 4, client);
    }
    GameRules_SetProp("m_bShowMatchSummary", 1);
    GameRules_SetProp("m_eRematchState", 1);

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client))
        {
            ShowVGUIPanel(client, "scores", null, false);
        }
    }

    CreateTimer(HUD_INIT_DELAY, Timer_ShowMatchSummary,
        g_iVoteRunSerial, TIMER_FLAG_NO_MAPCHANGE);
    DebugChatAll("[SM] Vote for the next map: %s / %s / %s.",
        g_szVoteMaps[0], g_szVoteMaps[1], g_szVoteMaps[2]);
}

public Action Timer_ShowMatchSummary(Handle timer, any serial)
{
    if (!g_bMapRunning || serial != g_iVoteRunSerial
        || (g_PostMatchPhase != PostMatch_Voting && g_PostMatchPhase != PostMatch_Chosen))
    {
        return Plugin_Stop;
    }
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client))
        {
            ShowClientMatchSummary(client);
        }
    }
    return Plugin_Stop;
}

void ShowClientMatchSummary(int client)
{
    if (!g_bMapRunning || client <= 0 || !IsClientInGame(client) || IsFakeClient(client)
        || g_hClientHudInit[client] != null
        || g_iClientSummaryRun[client] == g_iVoteRunSerial
        || (g_PostMatchPhase != PostMatch_Voting && g_PostMatchPhase != PostMatch_Chosen))
    {
        return;
    }
    ShowVGUIPanel(client, "scores", null, false);
    Event event = CreateEvent("show_match_summary", true);
    if (event != null)
    {
        event.FireToClient(client);
        event.Cancel();
        g_iClientSummaryRun[client] = g_iVoteRunSerial;
    }
}

bool ShouldSuppressIntermissionScoreboard()
{
    if (!g_bMapRunning || !IsSupportedGameMode())
    {
        return false;
    }
    if (g_PostMatchPhase != PostMatch_None)
    {
        return true;
    }

    return g_bPostMatchArmed && !g_bPostMatchAttempted
        && ((g_bSummaryTransition && GetGameTime() <= g_flSummaryTransitionUntil)
            || GameRules_GetRoundState() == RoundState_GameOver);
}

public Action Message_VguiMenu(UserMsg msgId, BfRead message, const int[] players,
    int playersNum, bool reliable, bool init)
{
    if (!ShouldSuppressIntermissionScoreboard())
    {
        return Plugin_Continue;
    }
    char panel[64];
    message.ReadString(panel, sizeof(panel));
    bool show = message.ReadByte() != 0;

    return show && StrEqual(panel, "scores") ? Plugin_Handled : Plugin_Continue;
}

void ShowNormalIntermissionScoreboard()
{
    if (!g_bMapRunning || GameRules_GetRoundState() != RoundState_GameOver)
    {
        return;
    }
    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client))
        {
            ShowVGUIPanel(client, "scores", null, true);
        }
    }
}

public Action Command_NextMapVote(int client, const char[] command, int args)
{
    if (g_PostMatchPhase != PostMatch_Voting && g_PostMatchPhase != PostMatch_Chosen)
    {
        return Plugin_Continue;
    }

    // Native next_map_vote requires GC match data; consume only our own vote session.
    if (g_PostMatchPhase != PostMatch_Voting || GetGameTime() >= g_flVoteDeadline
        || client <= 0 || !IsClientInGame(client) || IsFakeClient(client)
        || args != 1 || g_iPlayerVotes[client] != VOTE_UNDECIDED)
    {
        return Plugin_Handled;
    }
    char arg[16];
    GetCmdArg(1, arg, sizeof(arg));
    if (strlen(arg) != 1 || arg[0] < '0' || arg[0] > '2')
    {
        return Plugin_Handled;
    }
    int choice = arg[0] - '0';
    g_iPlayerVotes[client] = choice;
    GameRules_SetProp("m_ePlayerWantsRematch", choice, 4, client);
    ReplyToCommand(client, "[SM] Voted for %s.", g_szVoteMaps[choice]);
    return Plugin_Handled;
}

void TallyPostMatchVotes(int votes[VOTE_OPTION_COUNT])
{
    for (int i = 0; i < VOTE_OPTION_COUNT; i++)
    {
        votes[i] = 0;
    }
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }
        int choice = g_iPlayerVotes[client];
        if (choice >= 0 && choice < VOTE_OPTION_COUNT)
        {
            votes[choice]++;
        }
    }
}

void ResolvePostMatchVote()
{
    int votes[VOTE_OPTION_COUNT];
    TallyPostMatchVotes(votes);
    int winner = 0;
    if (votes[0] + votes[1] + votes[2] > 0)
    {
        // Match the native winner card: later slots win ties; zero votes use slot zero.
        for (int i = 1; i < VOTE_OPTION_COUNT; i++)
        {
            if (votes[i] >= votes[winner])
            {
                winner = i;
            }
        }
    }
    if (!SetNextMap(g_szVoteMaps[winner]))
    {
        DebugPrint("[SM] Voted map is no longer available; keeping the server's normal rotation.");
        GameRules_SetProp("m_eRematchState", 0);
        g_PostMatchPhase = PostMatch_Chosen;
        return;
    }
    g_cvNextLevel.SetString(g_szVoteMaps[winner]);
    g_iWinningMap = winner;
    g_PostMatchPhase = PostMatch_Chosen;
    GameRules_SetProp("m_eRematchState", 2);
    char currentMap[CASUAL_MAP_NAME_LENGTH];
    GetCurrentMap(currentMap, sizeof(currentMap));
    if (StrEqual(currentMap, g_szVoteMaps[winner], false))
    {
        DebugChatAll("[SM] %s won (%d votes). Reloading this map for a fresh match; the server stays running.",
            g_szVoteMaps[winner], votes[winner]);
    }
    else
    {
        DebugChatAll("[SM] Next map: %s (%d votes). Loading when intermission ends.",
            g_szVoteMaps[winner], votes[winner]);
    }
}

void CleanupPostMatch()
{
    delete g_hEndMapTimer;
    if (g_bMapRunning && (g_PostMatchPhase == PostMatch_Voting || g_PostMatchPhase == PostMatch_Chosen))
    {
        GameRules_SetProp("m_eRematchState", 0);
        GameRules_SetProp("m_bShowMatchSummary", 0);
    }
    g_PostMatchPhase = PostMatch_None;
    g_bSummaryTransition = false;
    g_iVoteRunSerial++;
    g_bPostMatchArmed = false;
    RestoreVoteIntermission();
}

/* ============================================================================
 *  MUSIC / FINAL MATCH VICTORY & DEFEAT
 * ========================================================================== */

void ResetFinalMatchAudio()
{
    g_bFinalResultKnown = false;
    g_bFinalMusicPlayed = false;
    g_bFinalMusicEnabled = false;
    g_iFinalWinningTeam = 0;
}

public Action Event_WinPanel(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bMapRunning || !IsSupportedGameMode() || g_CountdownPhase != Countdown_None
        || g_PostMatchPhase != PostMatch_None)
    {
        return Plugin_Continue;
    }

    // game_over is sent before stock result music; full_round is NOT a final-match flag.
    g_bFinalResultKnown = event.GetBool("game_over");
    if (g_bFinalResultKnown)
    {
        g_bFinalMusicEnabled = g_cvMusicEnabled.BoolValue;
        g_iFinalWinningTeam = event.GetInt("winning_team");
        RequestFrame(Frame_PlayFinalMatchMusic, g_iMapSerial);
    }
    return Plugin_Continue;
}

void Frame_PlayFinalMatchMusic(any serial)
{
    if (serial == g_iMapSerial && g_bMapRunning && g_bFinalResultKnown)
    {
        PlayFinalMatchMusic();
    }
}

bool IsStockResultSound(const char[] sound)
{
    return StrEqual(sound, "Game.YourTeamWon")
        || StrEqual(sound, "Game.YourTeamLost")
        || StrEqual(sound, "Game.Stalemate")
        || StrEqual(sound, "Game.TeamWin2")
        || StrEqual(sound, "Game.TeamWin3")
        || StrEqual(sound, "MatchMaking.RoundEndStalemateMusic");
}

public Action Event_BroadcastAudio(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bMapRunning || !g_bFinalMusicEnabled || !IsSupportedGameMode()
        || !g_bFinalResultKnown || g_CountdownPhase != Countdown_None)
    {
        return Plugin_Continue;
    }
    char sound[128];
    event.GetString("sound", sound, sizeof(sound));
    if (!IsStockResultSound(sound))
    {
        return Plugin_Continue;
    }

    event.BroadcastDisabled = true;
    PlayFinalMatchMusic();
    return Plugin_Changed;
}

void TickFinalMatchAudio()
{
    if (!g_bMapRunning || !IsSupportedGameMode() || g_bFinalMusicPlayed
        || GameRules_GetRoundState() != RoundState_GameOver)
    {
        return;
    }
    if (!g_bFinalResultKnown)
    {
        int red = GetTeamScore(2);
        int blue = GetTeamScore(3);
        g_iFinalWinningTeam = red == blue ? 0 : (red > blue ? 2 : 3);
        g_bFinalResultKnown = true;
        g_bFinalMusicEnabled = g_cvMusicEnabled.BoolValue;
    }
    PlayFinalMatchMusic();
}

void PlayFinalMatchMusic()
{
    if (!g_bMapRunning || !g_bFinalMusicEnabled || g_bFinalMusicPlayed
        || !g_bFinalResultKnown || !IsSupportedGameMode())
    {
        return;
    }
    g_bFinalMusicPlayed = true;

    for (int team = 2; team <= 3; team++)
    {
        Event event = CreateEvent("teamplay_broadcast_audio", true);
        if (event != null)
        {
            event.SetInt("team", team);
            event.SetInt("player", -1);
            event.SetInt("additional_flags", 0);
            event.SetString("sound", team == g_iFinalWinningTeam ? SOUND_CASUAL_WIN : SOUND_CASUAL_LOSE);
            event.Fire();
        }
    }
}
