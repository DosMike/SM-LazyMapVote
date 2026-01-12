#include <sdktools>
#include <sdkhooks>
#include <entity>
#include "include/playerbits"
#include <tf2_stocks>

#pragma semicolon 1
#pragma newdecls required
#define PLUGIN_VERSION     "26w03a"

#define CHAT_PREFIX        "\x01;[\x07;b064ffLMV\x01;] "
// for tierd votes
#define RTV_GROUPS_IN_VOTE 6
// for untierd votes, or as fallback if maps_invote is <= 0
#define RTV_MAPS_IN_VOTE   9
// amount of time before map-ends, to start next map vote
#define MAPVOTE_TIMELEFT 365
#define MAPVOTE_COUNTDOWN 5
#define TIER1_VOTETIME 20
#define TIER2_VOTETIME 30
#define TIEBREAK_VOTETIME 25
#define UNTIERED_VOTETIME 45
// maximum amount of maps to be picked for tiebreaker vote
#define TIEBREAK_MAX_ENTRIES 5
#define MAX_NOMINATIONS_PER_USER 3
// how many rounds before map end to trigger a vote
#define VOTE_ROUNDS_BACKOFF 1

#define CHANGEMAP_NOW "now"
#define CHANGEMAP_ROUND_END "round"
#define CHANGEMAP_MAP_END "map"

public Plugin myinfo =
{
    name        = "Lazy Map Vote",
    author      = "reBane",
    version     = PLUGIN_VERSION,
    description = "Sleek performat map vote system for LazyPurple Servers"
};

char currentConfig[PLATFORM_MAX_PATH] = "";
ArrayList groupnames; // group names in config order
StringMap mapgroups;    // all data here
enum struct MapGroup
{
    char      name[64];       // self ref
    int       mapsInvote;     // how many maps in this group are picked for vote
    char      exec[128];
    int       nominateFlags;  // admin flag bits to nominate. staff can still change map to hidden maps
    StringMap maps;

    bool CanClientNominate(int client) {
        if (client == 0 || this.nominateFlags == 0) return true;
        else if (!IsClientAuthorized(client)) return false;
        else return (GetUserAdmin(client).GetFlags(Access_Effective) & this.nominateFlags) != 0;
    }
}
enum struct MapEntry
{
    char name[64];        // self ref
    char workshopId[16];  // load workshop ref instead, numeric
    char exec[128];
    int  nominateFlags;   // admin flag bits to nominate. staff can still change map to hidden maps

    bool CanClientNominate(int client) {
        if (client == 0 || this.nominateFlags == 0) return true;
        else if (!IsClientAuthorized(client)) return false;
        else return (GetUserAdmin(client).GetFlags(Access_Effective) & this.nominateFlags) != 0;
    }
}
enum struct NominationEntry
{
    char group[64];
    char map[64];
    int userId;
}
// dumb wrapper for tie breakers
enum struct VoteHelper
{
    char index[16];
    char display[64];
}

enum RTVProgress
{
    RTV_NOT_VOTED = 0,
    RTV_SCHEDULED = 1,
    RTV_TIER1_RUNNING = 2,
    RTV_TIER2_RUNNING = 3,
    RTV_VOTE_COMPLETE = 4,
    RTV_TRANSITION = 5,  // map is trnasitioning
    RTV_ERROR = 100,    // if we enter this state, we don't recover until map change, something is broken!
}
enum VoteSource
{
    Vote_NotRunning = 0,
    Vote_Players,
    Vote_MapEnd,
    Vote_Forced,
    Vote_NativeCall,
}
// keep in mind that the key buffer is small!
#define INFO_PICKRANDOM ":item:rng"

PlayerBits  rtv_vote;
PlayerBits  g_playersIngame;  // track players ingame
Menu        nom_menus[MAXPLAYERS];    // per client nomination menus
DataPack    nom_data[MAXPLAYERS];     // nomination menu extra data
RTVProgress rtv_state;
int         g_mapTime;
ConVar      cvar_mapcyclefile;
ConVar      cvar_rtv_quota;
ConVar      cvar_rtv_enabled;
ConVar      cvar_rtv_cooldown;
ConVar      cvar_tiebreaker;
ConVar      cvar_tieredvote;
ConVar      cvar_randompick;
ConVar      cvar_blockedslots;
ConVar      cvar_maxrounds;
ConVar      cvar_winlimit;
ArrayList   nominations;
VoteSource  vote_source;
MapChange   vote_change;
char        voted_group[64];
char        voted_map[64];
#define RECENT_MAP_COUNT 10
char        recent_maps[RECENT_MAP_COUNT][64];
int         recent_mapptr = 0;
bool        configConvarChageLock = false; ///< prevent recusrive loads through config changes
// this list needs to survive a vote so we can map from a menu index back to the item
// it's reused by every vote because only one vote can run at a time
ArrayList   vctl_candidates;
int         g_rounds;

#include "lmv_natives.sp"

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    initNatives();
}

public void OnPluginStart()
{
    mapgroups         = new StringMap();
    groupnames        = new ArrayList(ByteCountToCells(64));
    nominations       = new ArrayList(sizeof(NominationEntry));
    vctl_candidates   = new ArrayList(ByteCountToCells(64));

    for (int client = 1; client < MaxClients; client++) {
        if (IsClientInGame(client) && IsClientAuthorized(client)) {
            g_playersIngame.Set(client, true);
        }
    }

    RegConsoleCmd("sm_rtv", CommandRTV, "Rock the vote");
    RegConsoleCmd("sm_nominate", CommandNominate, "Rock the vote");
    RegAdminCmd("sm_setnextmap", CommandSetNextmap, ADMFLAG_CHANGEMAP, "Arguments: <mapname> [when] - Change map to specified map, workshop supported. If 'when' is specified, change after 0/now 1/round 2/map");
    RegAdminCmd("sm_forcemapvote", CommandForceVote, ADMFLAG_CHANGEMAP, "Arguments: [when] - Force a map vote. If 'when' is specified, change after 0/now 1/round 2/map");
    AddCommandListener(CommandHookMap, "sm_map");

    cvar_mapcyclefile = CreateConVar("sm_lmv_mapcycle", "", "The mapcycle file to use, will autodetect if left empty or missing");
    cvar_rtv_quota    = CreateConVar("sm_lmv_rtv_quota", "40", "Amount of players that have to rock the vote to start map voting", _, true, 0.0, true, 100.0);
    cvar_rtv_enabled  = CreateConVar("sm_lmv_rtv_enabled", "1", "Set to 1 to allow rtv", _, true, 0.0, true, 1.0);
    cvar_rtv_cooldown = CreateConVar("sm_lmv_rtv_cooldown", "10", "Minutes after map start, before rtv is enabled", _, true, 0.0);
    cvar_tiebreaker   = CreateConVar("sm_lmv_tiebreaker", "2", "If not negative, start another vote if some results are less than this amount of votes away from the top result.", _, true, -1.0, false);
    cvar_tieredvote   = CreateConVar("sm_lmv_tieredvote", "0", "If enabled, map votes will vote for a group first, otherwise maps are just voted directly", _, true, 0.0, true, 1.0);
    cvar_randompick   = CreateConVar("sm_lmv_randompick", "0", "If enabled, a 'Pick Random' option will be available for map votes", _, true, 0.0, true, 1.0);
    cvar_blockedslots = CreateConVar("sm_lmv_blockedslots", "0", "Block this amount of slots in the vote menu on page 1, to prevent accidental voting", _, true, 0.0, true, 8.0);
    AutoExecConfig();
    cvar_mapcyclefile.AddChangeHook(OnCvarConfigChange);
    ConVar cvar = CreateConVar("sm_lmv_version", PLUGIN_VERSION, "Lazy Map Vote Version", FCVAR_NOTIFY);
    cvar.AddChangeHook(OnCvarVersionChange);
    cvar.SetString(PLUGIN_VERSION);
    delete cvar;

    cvar_maxrounds = FindConVar("mp_maxrounds");
    cvar_winlimit = FindConVar("mp_winlimit");
    ConVar cvar_bonusroundtime = FindConVar("mp_bonusroundtime");
    if (cvar_bonusroundtime) {
		cvar_bonusroundtime.SetBounds(ConVarBound_Upper, true, 30.0);
	}
    HookEvent("teamplay_win_panel", OnEvent_TeamplayWinPanel);
    HookEvent("arena_win_panel", OnEvent_TeamplayWinPanel);
    HookEvent("teamplay_restart_round", OnEvent_TeamplayRestartRound);
    HookEvent("teamplay_round_start", OnEvent_TeamplayRoundStart);
}

bool IsPluginActiveByFileName(char[] name) {
    Handle plugin = FindPluginByFile(name);
    if (plugin == null) return false;
    PluginStatus status = GetPluginStatus(plugin);
    return status == Plugin_Loaded || status == Plugin_Running;
}
public void OnAllPluginsLoaded()
{
    bool smPluginsLoaded;
    smPluginsLoaded |= IsPluginActiveByFileName("mapchooser.smx");
    smPluginsLoaded |= IsPluginActiveByFileName("nominations.smx");
    smPluginsLoaded |= IsPluginActiveByFileName("randomcycle.smx");
    smPluginsLoaded |= IsPluginActiveByFileName("rockthevote.smx");

    if (smPluginsLoaded) {
        SetFailState("Vanilla SourceMod Map Vote System is active");
    }
}

void OnCvarVersionChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!StrEqual(newValue, PLUGIN_VERSION)) convar.SetString(PLUGIN_VERSION);
}

void OnCvarConfigChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (configConvarChageLock) return;
    if (StrContains(newValue, ".") > 0 && !FileExists(newValue)) {
        PrintToChatAll(CHAT_PREFIX... "Warning: Invalid mapcycle file \"%s\" - File not found", newValue);
        convar.SetString("");
        return;
    }
    configConvarChageLock = true;
    LoadMapCycle(false);
    configConvarChageLock = false;
}

public void OnServerExitHibernation()
{
    OnMapEnd();
    rtv_state = RTV_NOT_VOTED;
}

public void OnMapStart()
{
    g_rounds = 0;
    g_mapTime = 0;
    CreateTimer(1.0, Timer_MapTime, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    char buffer[64];
    GetCurrentMap(buffer, sizeof(buffer));
    GetMapDisplayName(buffer, recent_maps[recent_mapptr], sizeof(recent_maps[]));
    recent_mapptr = (recent_mapptr + 1) % RECENT_MAP_COUNT;

    nominations.Clear();
    rtv_vote.XorBits(rtv_vote);
    vctl_candidates.Clear();

    RequestFrame(DelayedConfig);
}

public void OnConfigsExecuted()
{
    LoadMapCycle(true);
}

public void OnMapEnd()
{
    rtv_state = RTV_TRANSITION;
    vote_source = Vote_NotRunning;
    vote_change = MapChange_MapEnd;
    nominations.Clear();
    rtv_vote.XorBits(rtv_vote);
    vctl_candidates.Clear();
}

public void OnEvent_TeamplayRestartRound(Event event, const char[] name, bool dontBroadcast)
{
    g_rounds = 0;
}

// fix some weird winpanel rewrite
bool debounceRound = false;
public void OnEvent_TeamplayRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    debounceRound = false;
    // PrintToConsoleAll("Hook: TeamplayRoundStart");
}

public void OnEvent_TeamplayWinPanel(Event event, const char[] name, bool dontBroadcast)
{
    if (debounceRound) return;
    else debounceRound = true;
    // PrintToConsoleAll("Hook: TeamplayWinPanel");

    if (vote_change == MapChange_RoundEnd && rtv_state == RTV_VOTE_COMPLETE) {
        LogMessage("[LazyMapVote] Map is over and vote finished, switching map in 2");
        ForceNextMap(2);
        return;
    }
    if (rtv_state > RTV_SCHEDULED) {
        return;
    }

    if (event.GetInt("round_complete") == 1 || StrEqual(name, "arena_win_panel")) {
        g_rounds++;
        // PrintToConsoleAll("Tracked rounds played: %d", g_rounds);

        if (cvar_maxrounds) {
            int maxrounds = cvar_maxrounds.IntValue;
            if (maxrounds > 0 && g_rounds >= maxrounds - VOTE_ROUNDS_BACKOFF) {
                LogMessage("[LazyMapVote] Last round (%d), vote map!", g_rounds);
                TriggerVote(Vote_MapEnd, MapChange_MapEnd);
                return;
            }
        }

        int winlimit;
        if (cvar_winlimit) {
            winlimit = cvar_winlimit.IntValue;
        }
        int bluescore = event.GetInt("blue_score");
        int redscore = event.GetInt("red_score");

        // PrintToConsoleAll("Score: Red %d Blu %d Limit %d", redscore, bluescore, winlimit);

        switch(event.GetInt("winning_team")) {
            case 3: {
                if (winlimit > 0 && bluescore >= (winlimit - VOTE_ROUNDS_BACKOFF)) {
                    LogMessage("[LazyMapVote] Win limit blue (%d), vote map!", winlimit);
                    TriggerVote(Vote_MapEnd, MapChange_MapEnd);
                }
            }
            case 2: {
                if (winlimit > 0 && redscore >= (winlimit - VOTE_ROUNDS_BACKOFF)) {
                    LogMessage("[LazyMapVote] Win limit red (%d), vote map!", winlimit);
                    TriggerVote(Vote_MapEnd, MapChange_MapEnd);
                }
            }
            default: {
                return;
            }
        }
    }
}

void DelayedConfig()
{
    MapGroup group;
    MapEntry entry;
    if (voted_group[0] && mapgroups.GetArray(voted_group, group, sizeof(MapGroup))) {
        if (group.exec[0]) {
            ServerCommand("%s", group.exec);
        }
        if (voted_map[0] && group.maps.GetArray(voted_map, entry, sizeof(MapEntry))) {
            if (entry.exec[0]) {
                ServerCommand("%s", entry.exec);
            }
        }
    }

    voted_group[0] = 0;
    voted_map[0]   = 0;
}

void Timer_MapTime(Handle timer)
{
    g_mapTime++;
    int timeLeft;
    if (!GetMapTimeLeft(timeLeft)) return;
    if (timeLeft > 0 && timeLeft <= MAPVOTE_TIMELEFT && rtv_state == RTV_NOT_VOTED) {
        rtv_state = RTV_SCHEDULED;
        CreateTimer(1.0, Timer_VoteCountdown, MAPVOTE_COUNTDOWN, TIMER_FLAG_NO_MAPCHANGE);
    }
}

void Timer_VoteCountdown(Handle timer, int countDown)
{
    if (rtv_state > RTV_SCHEDULED) {
        return;
    } else if (countDown <= 0) {
        TriggerVote(Vote_MapEnd, MapChange_MapEnd);
    } else {
        if (countDown != 1)
            PrintHintTextToAll("%d seconds until vote", countDown);
        else
            PrintHintTextToAll("%d second until vote", countDown);
        CreateTimer(1.0, Timer_VoteCountdown, countDown - 1, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public void OnClientAuthorized(int client)
{
    g_playersIngame.Set(client, true);
    CheckRTV(client, false);
}

public void OnClientDisconnect(int client)
{
    g_playersIngame.Set(client, false);
    // RemoveClientNominations(client);
    CheckRTV(client, false);
}

// utilities

bool FindGroupForMap(const char[] mapname, char[] groupname, int maxlength) {
    char buffer[64];
    bool result = false;
    MapGroup group;
    // we had no group vote, find a group!
    for (int i; i < groupnames.Length; i++) {
        groupnames.GetString(i, buffer, sizeof(buffer));
        mapgroups.GetArray(buffer, group, sizeof(MapGroup));

        if (group.maps.ContainsKey(mapname)) {
            strcopy(groupname, maxlength, buffer);
            result = true;
            break;
        }
    }
    return result;
}

int CountClientsForVote() {
    int clients = 0;
    for (int i=1; i<=MaxClients; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i) && !IsClientReplay(i) && IsClientAuthorized(i))
            clients += 1;
    }
    return clients;
}

bool PickRandomGroup()
{
    if (vctl_candidates.Length == 0 || rtv_state != RTV_TIER1_RUNNING)
        return false;
    vctl_candidates.GetString(GetRandomInt(0,vctl_candidates.Length-1), voted_group, sizeof(voted_group));
    return true;
}

/* this is a fallback solution, to avoid dropping out of our mapcycle */
void PickRandomMap(ArrayList fromList = null)
{
    if (fromList != null && fromList.Length > 0) {
        fromList.GetString(GetRandomInt(0, fromList.Length - 1), voted_map, sizeof(voted_map));
        if (FindGroupForMap(voted_map, voted_group, sizeof(voted_group)))
            return;
    }
    if (groupnames.Length == 0) {
        LogError("[LazyMapVote] Could not auto pick next map from mapcycle, no groups");
        return;
    }
    int safety=0;
    for (; safety<100; safety++) {
        // random group
        groupnames.GetString(GetRandomInt(0, groupnames.Length - 1), voted_group, sizeof(voted_group));
        MapGroup group;
        mapgroups.GetArray(voted_group, group, sizeof(group));
        if (group.nominateFlags != 0) continue; // group requires admin flag
        // random map
        if (group.maps.Size == 0) continue; // no map in group, try again
        StringMapSnapshot snap = group.maps.Snapshot();
        snap.GetKey(GetRandomInt(0, snap.Length - 1), voted_map, sizeof(voted_map));
        delete snap;
        MapEntry entry;
        group.maps.GetArray(voted_map, entry, sizeof(MapEntry));
        if (entry.nominateFlags != 0) continue; // map requires admin flag

        // make sure our pick is not a recent map
        bool recent = false;
        for (int i; i<RECENT_MAP_COUNT; i++) {
            if (StrEqual(voted_map, recent_maps[i])) {
                recent = true; break;
            }
        }
        if (!recent) break;
    }
    if (safety >= 100) {
        LogError("[LazyMapVote] Could not auto pick next map from mapcycle, gave up after %d tries", safety);
    }
}

static bool ParseMapChangeTime(const char[] value, MapChange& when) {
    if (StrEqual("0", value) || StrContains(value, "now", false) != -1) {
        when = MapChange_Instant;
    } else if (StrEqual("1", value) || StrContains(value, "round", false) != -1) {
        when = MapChange_RoundEnd;
    } else if (StrEqual("2", value) || StrContains(value, "map", false) != -1) {
        when = MapChange_MapEnd;
    } else {
        return false;
    }
    return true;
}

static void SetNextMapIntern(bool requireInGroup = true, bool title = false)
{
    LogMessage("[LazyMapVote] SetNextMap context: %s::%s vc:%s vs:%s rtv:%s",
        voted_group, voted_map, enum2str_MapChange(vote_change), enum2str_VoteSource(vote_source), enum2str_RTVProgress(rtv_state));
    char     buffer[64];
    // load the entry to get meta data
    if (voted_group[0] == 0) {
        // we had no group vote, find a group!
        if (!FindGroupForMap(voted_map, voted_group, sizeof(voted_group)) && requireInGroup) {
            LogError("[LazyMapVote] Could not find group for map '%s'!", voted_map);
            rtv_state = RTV_ERROR;
            return;
        }
    }
    // load entry data, if we have a group
    MapGroup group;
    MapEntry entry;
    if (voted_group[0] != 0) { // requireInGroup was already checked above, if we have no group here, that should be fine
        mapgroups.GetArray(voted_group, group, sizeof(MapGroup));
        if (group.maps == null || !group.maps.GetArray(voted_map, entry, sizeof(MapEntry))) {
            LogError("[LazyMapVote] Map vote result %s not in group %s!", voted_map, voted_group);
        }
    }

    FindMapResult result = FindMap(voted_map, buffer, 0);
    if (result == FindMap_NotFound || result == FindMap_PossiblyAvailable) {
        LogError("[LazyMapVote] Nextmap '%s' does not exist or is not synced! - Check mapcycle file!", voted_map);
        PrintToChatAll(CHAT_PREFIX... "Could not find map %s", voted_map);
        rtv_state = RTV_ERROR;
        return;
    }

    // voted_group / voted_map are now keys that should survive map change (unless config changes)
    // for later lookups on commands we need to run
    if (entry.workshopId[0] != 0) {
        FormatEx(buffer, sizeof(buffer), "workshop/%s", entry.workshopId);
        LogMessage("[LazyMapVote] redirecting map entry %s to %s", voted_map, buffer);
        if (!SetNextMap(buffer)) {
            LogError("[LazyMapVote] SetNextMap failed for '%s', setting sm_nextmap directly", buffer);
        }
    } else {
        if (!SetNextMap(voted_map)) {
            LogError("[LazyMapVote] SetNextMap failed for '%s', setting sm_nextmap directly", voted_map);
        }
    }
    char displayName[128];
    GetMapDisplayName(voted_map, displayName, sizeof(displayName));
    PrintToChatAll(CHAT_PREFIX... "Next Map is: %s", displayName);
    if (title) {
        PrintCenterTextAll("[LMV] Next Map is: %s", displayName);
    }
}

void HandleMapVoteResult()
{
    rtv_state = RTV_VOTE_COMPLETE;
    vctl_candidates.Clear();

    SetNextMapIntern();

    if (vote_change == MapChange_Instant)  {
        ForceNextMap(.delay=5);
    }
}

int RemoveClientNominations(int client) {
    NominationEntry entry;
    int count;
    for (int i=nominations.Length-1; i>=0; i--) {
        nominations.GetArray(i, entry, sizeof(NominationEntry));
        int owner = GetClientOfUserId(entry.userId);
        if (client == owner) {
            count ++;
            nominations.Erase(i);
            Notify_OnNominationRemoved(entry.map, owner);
        }
    }
    return count;
}

bool DoClientNomination(int client, const char[] group, const char[] map)
{
    if (groupnames.FindString(group) == -1) {
        PrintToChat(client, CHAT_PREFIX... "The mapcycle file was reloaded!");
        return false;
    }
    MapGroup mapgroup;
    MapEntry entry;
    if (!mapgroups.GetArray(group, mapgroup, sizeof(MapGroup)) ||
        !mapgroup.maps.GetArray(map, entry, sizeof(MapEntry))) {
        PrintToChat(client, CHAT_PREFIX... "The mapcycle file was reloaded!");
        return false;
    } else if (!entry.CanClientNominate(client)) {
        PrintToChat(client, CHAT_PREFIX... "You can not nominate this map right now");
        return false;
    }

    NominationEntry nominate;
    strcopy(nominate.group, sizeof(NominationEntry::group), group);
    strcopy(nominate.map, sizeof(NominationEntry::map), map);
    nominate.userId = 0;
    if (client) nominate.userId = GetClientUserId(client);

    if (nominations.FindString(map, NominationEntry::map) == -1) {
        nominations.PushArray(nominate, sizeof(NominationEntry));
        if (client) {
            PrintToChatAll(CHAT_PREFIX... "%N nominated map %s", client, map);
        } else {
            PrintToChatAll(CHAT_PREFIX... "The map %s was nominated", map);
        }
        return true;
    }
    PrintToChat(client, CHAT_PREFIX... "%s was already nominated", map);
    return false;
}

// config

static void LoadMapCycle(bool force)
{
    // read new mapcycle file
    char filename[PLATFORM_MAX_PATH];
    cvar_mapcyclefile.GetString(filename, sizeof(filename));

    KeyValues file; bool success=false;
    if (StrContains(filename, ".") < 0 || !FileExists(filename)) {
        if (FileExists("umc_mapcycle.txt")) {
            strcopy(filename, sizeof(filename), "umc_mapcycle.txt");
            cvar_mapcyclefile.SetString(filename);
            file = new KeyValues("umc_mapcycle");
            success = file.ImportFromFile(filename);
        } else if (FileExists("lazy_mapcycle.txt")) {
            strcopy(filename, sizeof(filename), "lazy_mapcycle.txt");
            cvar_mapcyclefile.SetString(filename);
            file = new KeyValues("lazy_mapcycle");
            success = file.ImportFromFile(filename);
        } else {
            LogError("[LazyMapVote] Could not open mapcycle file - No default config found");
        }
    } else {
        file = new KeyValues("lazy_mapcycle");
        success = file.ImportFromFile(filename);
    }
    if (!success) {
        LogError("[LazyMapVote] Could not open mapcycle file!");
        rtv_state = RTV_ERROR; // dont allow voting
        delete file;
        return;
    } else if (!force && StrEqual(currentConfig, filename)) {
        delete file;
        return;
    } else {
        strcopy(currentConfig, sizeof(currentConfig), filename);
    }

    LogMessage("[LazyMapVote] Loading mapcycle from '%s'", currentConfig);

    OnMapEnd();
    rtv_state = RTV_NOT_VOTED;
    char key[64];

    // destroy existing groups
    MapGroup          group;
    for (int i; i < groupnames.Length; i++) {
        groupnames.GetString(i, key, sizeof(key));
        mapgroups.GetArray(key, group, sizeof(group));
        delete group.maps;
    }
    mapgroups.Clear();
    groupnames.Clear();

    if (!file.GotoFirstSubKey(true)) {
        LogError("[LazyMapVote] Could not read mapcycle file!");
        return;
    }
    do {
        LoadMapGroup(file);
    } while (file.GotoNextKey(true));

    delete file;
}

static void LoadMapGroup(KeyValues file)
{
    char     key[64];
    int      bigint[2];
    char     buffer[32];
    MapGroup group;
    MapEntry entry;

    file.GetSectionName(key, sizeof(key));
    if (!file.GotoFirstSubKey(false)) {
        LogError("[LazyMapVote] Empty map group '%s'!", key);
        return;
    }
    if (!mapgroups.GetArray(key, group, sizeof(MapGroup))) {
        group.maps        = new StringMap();
        group.exec[0]     = 0;
        group.mapsInvote  = 0;
        group.nominateFlags = 0;
        strcopy(group.name, sizeof(MapGroup::name), key);
        groupnames.PushString(key);
    }

    do {
        file.GetSectionName(key, sizeof(key));

        if (StrEqual(key, "command")) {
            file.GetString(NULL_STRING, group.exec, sizeof(MapGroup::exec));
        } else if (StrEqual(key, "maps_invote")) {
            group.mapsInvote = file.GetNum(NULL_STRING);
        } else if (StrEqual(key, "nominate_flags")) {
            file.GetString(NULL_STRING, buffer, sizeof(buffer));
            group.nominateFlags = ReadFlagString(buffer);
        } else if (file.GetDataType(key) != KvData_None) {
            LogError("[LazyMapVote] key '%s' in '%s' is not recognized - skipping!", key, group.name);
        } else {
            strcopy(entry.name, sizeof(entry.name), key);
            // exec on load
            file.GetString("command", entry.exec, sizeof(MapEntry::exec));
            // workshop id
            file.GetString("workshopid", entry.workshopId, sizeof(MapEntry::workshopId));
            if (entry.workshopId[0] != 0){
                if (StringToInt64(entry.workshopId, bigint) == strlen(entry.workshopId)) {
                    ServerCommand("tf_workshop_map_sync %s", entry.workshopId);
                } else {
                    LogError("[LazyMapVote] Map %s : %s has non-numeric workshop id '%s' - ignoring!", group.name, key, entry.workshopId);
                    entry.workshopId[0] = 0;
                }
            }
            // nomination flags
            file.GetString("nominate_flags", buffer, sizeof(buffer));
            entry.nominateFlags = ReadFlagString(buffer);
            // and store
            group.maps.SetArray(key, entry, sizeof(MapEntry));
        }

    } while (file.GotoNextKey(false));
    mapgroups.SetArray(group.name, group, sizeof(MapGroup));

    file.GoBack();
}

// other commands

/** input and output buffer can be the same */
bool FindWorkshopMapInCycle(const char[] lookup, char[] resolved, int maxlen) {
    char buffer[128];
    strcopy(buffer, sizeof(buffer), lookup);
    StripQuotes(buffer);
    TrimString(buffer);
    if (strncmp(buffer, "workshop/", 9, false) == 0) {
        strcopy(resolved, maxlen, buffer);
        return true; // sourcemod can load workshop maps
    }
    // check if we have a workshop alias for a give map

    // fuzzy find map
    char fuzz_exact[128], fuzz_start[128], fuzz_instr[128], groupname[64], mapname[128];
    int hits = 0;
    MapGroup group;
    MapEntry entry;
    for (int i; i<groupnames.Length && hits < 3; i++) {
        groupnames.GetString(i, groupname, sizeof(groupname));
        mapgroups.GetArray(groupname, group, sizeof(MapGroup));
        StringMapSnapshot snap = group.maps.Snapshot();
        for (int j; j<snap.Length && hits < 3; j++) {
            snap.GetKey(j, mapname, sizeof(mapname));
            group.maps.GetArray(mapname, entry, sizeof(MapEntry));

            if (entry.workshopId[0] == 0) continue; // not workshop, let sourcemod handle this
            int pos = StrContains(mapname, buffer, false);
            if (StrEqual(mapname, buffer, false)) {
                if (fuzz_exact[0] == 0) {
                    FormatEx(fuzz_exact, sizeof(fuzz_exact), "workshop/%s", entry.workshopId);
                    hits += 1;
                }
            } else if (pos == 0) {
                if (fuzz_start[0] == 0) {
                    FormatEx(fuzz_start, sizeof(fuzz_start), "workshop/%s", entry.workshopId);
                    hits += 1;
                }
            } else if (pos > 0) {
                if (fuzz_instr[0] == 0) {
                    FormatEx(fuzz_instr, sizeof(fuzz_instr), "workshop/%s", entry.workshopId);
                    hits += 1;
                }
            }
        }
        delete snap;
    }
    if (fuzz_exact[0]) {
        strcopy(resolved, maxlen, fuzz_exact);
        return true;
    } else if (fuzz_start[0]) {
        strcopy(resolved, maxlen, fuzz_start);
        return true;
    } else if (fuzz_instr[0]) {
        strcopy(resolved, maxlen, fuzz_instr);
        return true;
    }
    strcopy(resolved, maxlen, buffer);
    return false;
}
/** looks for map in mapcycle file, falls back to map directory, returns input if failed */
bool FindMapCustom(const char[] map, char[] mapfound, int maxlen) {
    if (FindWorkshopMapInCycle(map, mapfound, maxlen)) {
        return true;
    }
    FindMapResult result = FindMap(map, mapfound, maxlen);
    if (result == FindMap_Found || result == FindMap_FuzzyMatch || result == FindMap_NonCanonical) {
        return true;
    }
    strcopy(mapfound, maxlen, map);
    return false;
}

Action CommandHookMap(int client, const char[] command, int argc)
{
    char buffer[128];
    char mapfound[128];
    GetCmdArgString(buffer, sizeof(buffer));
    StripQuotes(buffer);
    TrimString(buffer);

    // see if a local name has a workshop mapping and load that instead
    bool isWorkShop = strncmp(buffer, "workshop/", 9, false) == 0;
    bool workShopFound = !isWorkShop && FindWorkshopMapInCycle(buffer, mapfound, sizeof(mapfound));
    if (workShopFound) {
        // we assume the result to always be valid - is this ok?
        if (client) {
            FakeClientCommandEx(client, "sm_map %s", mapfound);
        } else {
            ServerCommand("sm_map %s", mapfound);
        }
        return Plugin_Stop;
    }

    // let sourcemods implementation do the rest
    return Plugin_Continue;
}

Action CommandSetNextmap(int client, int args)
{
    char buffer[128];
    char mapname[128];
    MapChange when = MapChange_MapEnd;
    bool invalidCall = false;
    if (args == 0 || args > 2) {
        invalidCall = true;
    } else if (args == 2 && (GetCmdArg(2, buffer, sizeof(buffer)) == 0 || !ParseMapChangeTime(buffer, when))) {
        invalidCall = true;
    }
    if (invalidCall) {
        GetCmdArg(0, buffer, sizeof(buffer));
        for (int i = 0; i < strlen(buffer); i++) {
            if ('A' <= buffer[i] <= 'Z')
                buffer[i] |= 32;
        }
        ReplyToCommand(client, CHAT_PREFIX... "Usage: %s <mapname> [when] - Change map to specified map, workshop supported. If 'when' is specified, change after 0/now 1/round 2/map", buffer);
        return Plugin_Handled;
    }

    GetCmdArg(1, buffer, sizeof(buffer));
    if (!FindMapCustom(buffer, mapname, sizeof(mapname))) {
        ReplyToCommand(client, CHAT_PREFIX... "No map found for '%s'", buffer);
        return Plugin_Handled;
    }
    if (rtv_state == RTV_TIER1_RUNNING || rtv_state == RTV_TIER2_RUNNING) {
        // we can skip the vote, staff has chosen!
        CancelVote();
    }
    rtv_state      = RTV_VOTE_COMPLETE;
    voted_group[0] = 0;    // force group lookup
    vote_source    = Vote_Forced;
    vote_change    = when;
    strcopy(voted_map, sizeof(voted_map), mapname);
    SetNextMapIntern(.requireInGroup=false, .title=true);
    return Plugin_Handled;
}

Action CommandForceVote(int client, int args)
{
    MapChange when = MapChange_MapEnd;
    bool invalidCall = false;
    char buffer[32];
    if (args >= 2) {
        invalidCall = true;
    } else if (args == 1 && (GetCmdArg(1, buffer, sizeof(buffer)) == 0 || !ParseMapChangeTime(buffer, when))) {
        invalidCall = true;
    }
    if (invalidCall) {
        GetCmdArg(0, buffer, sizeof(buffer));
        for (int i = 0; i < strlen(buffer); i++) {
            if ('A' <= buffer[i] <= 'Z')
                buffer[i] |= 32;
        }
        ReplyToCommand(client, CHAT_PREFIX... "Usage: %s <mapname> [when] - Change map to specified map, workshop supported. If 'when' is specified, change after 0/now 1/round 2/map", buffer);
        return Plugin_Handled;
    }

    GetCmdArg(1, buffer, sizeof(buffer));
    if (rtv_state >= RTV_TRANSITION) {
        ReplyToCommand(client, CHAT_PREFIX... "A map vote already concluded");
    } else if (rtv_state >= RTV_TIER1_RUNNING && rtv_state < RTV_VOTE_COMPLETE) {
        ReplyToCommand(client, CHAT_PREFIX... "A map vote is already in progress");
    } else {
        rtv_state = RTV_NOT_VOTED;
        TriggerVote(Vote_Forced, when);
    }
    return Plugin_Handled;
}

// nominations

Action CommandNominate(int client, int args)
{
    char buffer[64];
    char mapname[64];
    char groupname[64];

    // count client nominations
    int noms = 0;
    {
        int user;
        if (client) user = GetClientUserId(client);
        for (int i; i<nominations.Length; i++) {
            int nomuser = nominations.Get(i, NominationEntry::userId);
            if (user == nomuser) noms ++;
        }
    }

    // check if we can rtv now
    if (rtv_state >= RTV_VOTE_COMPLETE) {
        ReplyToCommand(client, CHAT_PREFIX... "A map vote already concluded");
        return Plugin_Handled;
    } else if (rtv_state >= RTV_TIER1_RUNNING) {
        ReplyToCommand(client, CHAT_PREFIX... "A map vote is already in progress");
        return Plugin_Handled;
    } else if (noms >= MAX_NOMINATIONS_PER_USER) {
        ReplyToCommand(client, CHAT_PREFIX... "You can not nominate more maps this round");
        return Plugin_Handled;
    }

    if (args == 0) {
        // no map name give, show nomination menu
        ShowNominationGroupMenu(client);
        return Plugin_Handled;
    }

    GetCmdArgString(buffer, sizeof(buffer));
    StripQuotes(buffer);
    TrimString(buffer);

    // small fix for numbers, assume they mean a workshop id
    bool numeric = true;
    for (int i; buffer[i]; i++) {
        if (!('0'<=buffer[i]<='9')) numeric = false;
    }
    if (numeric) {
        Format(buffer, sizeof(buffer), "workshop/%s", buffer);
    }

    bool result = FindMapCustom(buffer, mapname, sizeof(mapname));
    PrintToConsole(client, "[LMV] Map lookup \"%s\" -> \"%s\" : %d", buffer, mapname, result);
    if (!result) {
        ReplyToCommand(client, CHAT_PREFIX... "Could not find map");
    } else if (!FindGroupForMap(mapname, groupname, sizeof(groupname))) {
        ReplyToCommand(client, CHAT_PREFIX... "This map is not on rotation");
    } else {
        // man name given, exists and on rotation
        DoClientNomination(client, groupname, mapname);
    }
    return Plugin_Handled;
}

void ShowNominationGroupMenu(int client, bool reopened=false)
{
    char buffer[64];
    MapGroup group;

    if (nom_data[client] == INVALID_HANDLE) nom_data[client] = new DataPack();
    else nom_data[client].Reset(true);

    if (groupnames.Length == 0) {
        PrintToChat(client, CHAT_PREFIX... "No map groups");
    } else if (groupnames.Length == 1) {
        if (reopened) return;
        groupnames.GetString(0, buffer, sizeof(buffer));
        mapgroups.GetArray(buffer, group, sizeof(MapGroup));
        if (!group.CanClientNominate(client)) {
            PrintToChat(client, CHAT_PREFIX... "You can not nominate any map groups");
        } else {
            nom_data[client].WriteString(buffer);
            ShowNominationMapMenu(client);
        }
        return;
    }

    int countedGroups = 0;
    Menu menu = new Menu(NominationGroupMenuHandler);
    menu.SetTitle("Nomiate map from group:");
    char key[4];
    for (int i; i < groupnames.Length; i++) {
        FormatEx(key, sizeof(key), "%d", i);
        groupnames.GetString(i, buffer, sizeof(buffer));
        mapgroups.GetArray(buffer, group, sizeof(MapGroup));
        if (group.CanClientNominate(client)) {
            countedGroups ++;
            menu.AddItem(key, buffer);
        }
    }
    if (countedGroups == 0) {
        PrintToChat(client, CHAT_PREFIX... "You can not nominate any map groups");
        delete menu;
        return;
    }
    menu.Display(client, MENU_TIME_FOREVER);
    menu.Pagination     = groupnames.Length <= 7 ? MENU_NO_PAGINATION : 7;
    menu.ExitBackButton = false;
    menu.ExitButton     = true;
    nom_menus[client]   = menu;
}

int NominationGroupMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action) {
        case MenuAction_Select: {
            char dummy[4];
            char buffer[64];
            menu.GetItem(param2, dummy, 0, _, buffer, sizeof(buffer));
            nom_data[param1].WriteString(buffer);
            ShowNominationMapMenu(param1);
        }
        case MenuAction_End: {
            delete menu;
        }
    }
    return 0;
}

void ShowNominationMapMenu(int client, int first = 0)
{
    char buffer[64];
    nom_data[client].Reset();
    nom_data[client].ReadString(buffer, sizeof(buffer));

    MapGroup group;
    MapEntry entry;
    mapgroups.GetArray(buffer, group, sizeof(MapGroup));
    if (group.maps.Size == 0) {
        PrintToChat(client, CHAT_PREFIX... "No maps in group");
        return;
    }

    // make a stable list of keys
    ArrayList         names = new ArrayList(ByteCountToCells(64));
    StringMapSnapshot snap  = group.maps.Snapshot();
    for (int i; i < snap.Length; i++) {
        snap.GetKey(i, buffer, sizeof(buffer));
        group.maps.GetArray(buffer, entry, sizeof(MapEntry));
        if (entry.CanClientNominate(client))
            names.PushString(buffer);
    }
    delete snap;
    names.Sort(Sort_Ascending, Sort_String);

    if (names.Length == 0) {
        PrintToChat(client, CHAT_PREFIX... "You can not nominate any maps in this group");
        ShowNominationGroupMenu(client, .reopened=true);
        return;
    }

    Menu menu = new Menu(NominationMapMenuHandler);
    menu.SetTitle("Nomiate %s map:", group.name);
    char key[4];
    for (int i; i < names.Length; i++) {
        FormatEx(key, sizeof(key), "%d", i);
        names.GetString(i, buffer, sizeof(buffer));
        menu.AddItem(key, buffer);
    }
    menu.Pagination     = 7;    // always 7 because we want an exit back button
    menu.ExitButton     = true;
    menu.ExitBackButton = true;
    menu.DisplayAt(client, first, MENU_TIME_FOREVER);
    nom_menus[client] = menu;
}

int NominationMapMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action) {
        case MenuAction_Select: {
            // we can't do this in end, so we need to manage this in every other case beforehand
            nom_menus[param1] = view_as<Menu>(INVALID_HANDLE);

            char group[64];
            nom_data[param1].Reset();
            nom_data[param1].ReadString(group, sizeof(group));
            char dummy[4];
            char entry[64];
            menu.GetItem(param2, dummy, 0, _, entry, sizeof(entry));

            for (int i; i < RECENT_MAP_COUNT; i++) {
                if (StrEqual(recent_maps[i], entry)) {
                    PrintToChat(param1, CHAT_PREFIX... "Map %s was nominated too recently", entry);
                    // reopen previous menu
                    int first = param2 - param2 % 7;    // round down to the next multiple of 7
                    ShowNominationMapMenu(param1, first);
                    return 0;
                }
            }

            if (!DoClientNomination(param1, group, entry)) {
                int first = param2 - param2 % 7;    // round down to the next multiple of 7
                ShowNominationMapMenu(param1, first);
            }
        }
        case MenuAction_Cancel: {
            nom_menus[param1] = view_as<Menu>(INVALID_HANDLE);
            if (param2 == MenuCancel_ExitBack) {
                ShowNominationGroupMenu(param1);
            }
        }
        case MenuAction_End: {
            delete menu;
        }
    }
    return 0;
}

// vote controller

Action CommandRTV(int client, int args)
{
    int cooldown = cvar_rtv_cooldown.IntValue * 60;
    if (rtv_state == RTV_TIER1_RUNNING || rtv_state == RTV_TIER2_RUNNING) {
        ReplyToCommand(client, CHAT_PREFIX... "A vote is already in progress");
    } else if (g_mapTime < cooldown) {
        ReplyToCommand(client, CHAT_PREFIX... "You can't vote for %d more seconds", cooldown - g_mapTime);
    } else {
        CheckRTV(client, true);
    }
    return Plugin_Handled;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (strncmp("rtv", sArgs, 3, false) == 0 && strlen(sArgs) == 3) {
        ReplySource restore = SetCmdReplySource(SM_REPLY_TO_CHAT); //yea we come from chat
        CommandRTV(client, 0);
        SetCmdReplySource(restore);
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

static void CheckRTV(int client, bool vote)
{
    bool hadVoted = rtv_vote.Get(client);
    if (!vote) {
        //always allow clearing
        rtv_vote.Set(client, false);
    }

    if (!IsClientInGame(client)) return;
    if (!cvar_rtv_enabled.BoolValue) {
        if (vote) {
            PrintToChat(client, CHAT_PREFIX, "RTV is currently disabled");
        }
        return;
    }
    if (rtv_state == RTV_NOT_VOTED) {
        // pass
    } else if (rtv_state >= RTV_ERROR) {
        PrintToChat(client, CHAT_PREFIX... "The vote plugin is currently in an error state, please tell a dev :3");
        return;
    } else if (RTV_NOT_VOTED < rtv_state <= RTV_TIER2_RUNNING || rtv_state == RTV_TRANSITION) {
        // silent fail. for running votes we already notify on command, and transition is too late/early to do anything
        return;
    } else if (vote && hadVoted && rtv_state < RTV_TRANSITION) {
        PrintToChat(client, CHAT_PREFIX... "You have already rocked the vote");
        return;
    }
    rtv_vote.Set(client, vote);
    int voted      = rtv_vote.Count();
    int players    = g_playersIngame.Count();
    int minplayers = RoundToCeil(cvar_rtv_quota.FloatValue / 100.0 * float(players));

    if (vote) {
        PrintToChatAll(CHAT_PREFIX... "%N wants to rock the vote (%d/%d votes)", client, voted, minplayers);
    } else if (voted >= minplayers) {
        PrintToChatAll(CHAT_PREFIX... "Updated player count hit vote quota!");
    }
    if (voted >= minplayers) {
        if (rtv_state == RTV_NOT_VOTED) {
            TriggerVote(Vote_Players, MapChange_Instant);
        } else if (rtv_state == RTV_VOTE_COMPLETE) {
            SetNextMapIntern();
            ForceNextMap();
        } else {
            PrintToChatAll(CHAT_PREFIX... "Invalid State (%d)", rtv_state);
            LogError("[LazyMapVote] Invalid rtv state %d", rtv_state);
            if (voted_map[0] != 0 && voted_group[0] != 0) {
                SetNextMapIntern();
                ForceNextMap(5);
            }
        }
    }
}

static void ForceNextMap(int delay=0)
{
    rtv_state = RTV_TRANSITION;
    char dummy[4];
    if (!GetNextMap(dummy, sizeof(dummy))) {
        LogError("[LazyMapVote] Entered ForceNextMap without next map being set - picking at random");
        PickRandomMap();
        SetNextMapIntern();
    }

    DataPack pack = new DataPack();
    pack.WriteCell(delay);
    CreateTimer(1.0, Timer_ChangeMapIn, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE | TIMER_REPEAT);
}

void Timer_ChangeMapIn(Handle timer, DataPack data)
{
    data.Reset();
    int delay = data.ReadCell();
    if (delay > 0) {
        data.Reset();
        data.WriteCell(delay-1);
    } else {
        char buffer[64];
        GetNextMap(buffer, sizeof(buffer));
        ForceChangeLevel(buffer, "LazyMapVote");
    }
}

void TriggerVote(VoteSource source, MapChange change)
{
    vote_source = source;
    vote_change = change;

    if (!cvar_tieredvote.BoolValue) {
        TriggerVoteUntiered();
    } else {
        TriggerVoteTier1();
    }
    Notify_OnMapVoteStarted();
}

static void AddRandomOption(Menu menu) {
    char labels[7][32] = {
        "The good, the bad, the random",
        "I dunno, you pick something",
        "Random! Random! Random!",
        "Sometimes, I dream about cheese",
        "Your nominations are all bad",
        "Anything but pl_poodoo",
        "Something weird or normal idk"
    };
    menu.AddItem(INFO_PICKRANDOM, labels[GetRandomInt(0,6)]);
}

static int RenderMenuHead(Menu menu) {
    int slots = cvar_blockedslots.IntValue;
    if (slots <= 0) {
        // this shit is broken, dont ask me
        // menu.NoVoteButton = true;
        // return 1;
        return 0;
    } else {
        for (int i; i<slots; i++) {
            char info[12] = ":blocker:0";
            char labels[8][20] = {
                "No weapon select",
                "Vote is running",
                "Blocked",
                "Empty",
                "Nope",
                "Nuh uh",
                "Don't think so",
                "See below",
            };
            menu.AddItem(info, labels[i], ITEMDRAW_DISABLED);
            info[9] += 1;
        }
        return slots;
    }
}

static void TriggerVoteUntiered()
{
    // make sure we have clients to vote
    if (CountClientsForVote() == 0) {
        PickRandomMap();
        HandleMapVoteResult();
        return;
    }

    vctl_candidates.Clear();
    rtv_state = RTV_TIER2_RUNNING;

    char              buffer[64];
    char              map[64];
    MapGroup          group;
    MapEntry          entry;
    // Iterate over all maps to create a flat list.
    // This will immediately move nominated maps into the vote controller.
    // Other maps are accumulated (up to maps_invote per group or _all_ if not specified) to
    // shuffle again in the end and from there pull random maps into the vote controller.
    ArrayList         mapnames  = new ArrayList(ByteCountToCells(64)); //candidates
    ArrayList         innerlist = new ArrayList(ByteCountToCells(64)); //group maps w/o noms
    for (int i; i < groupnames.Length; i++) {
        groupnames.GetString(i, buffer, sizeof(buffer));
        mapgroups.GetArray(buffer, group, sizeof(MapGroup));
        int invote = 0;
        innerlist.Clear();

        StringMapSnapshot snap = group.maps.Snapshot();
        for (int j; j < snap.Length; j++) {
            snap.GetKey(j, map, sizeof(map));
            group.maps.GetArray(map, entry, sizeof(MapEntry));

            if (nominations.FindString(map, NominationEntry::map) >= 0) {
                // nominated: immediately add
                if (vctl_candidates.FindString(map) == -1) {
                    vctl_candidates.PushString(map);
                    invote++;
                }
            } else if (entry.nominateFlags == 0 && innerlist.FindString(map) == -1) {
                // guards: no admin flags required and no duplicate
                // not nominated, maybe random strikes
                innerlist.PushString(map);
            }
        }
        delete snap;

        if (innerlist.Length == 0) continue;    // nothing else to add
        innerlist.Sort(Sort_Random, Sort_String);
        int maxPicks = group.mapsInvote;
        if (maxPicks <= 0) maxPicks = RTV_MAPS_IN_VOTE; // just pick some of every group if no limit is set
        for (int j; j < innerlist.Length && invote < maxPicks; j++) {
            innerlist.GetString(j, map, sizeof(map));
            mapnames.PushString(map);
            invote++;
        }
    }
    delete innerlist;
    mapnames.Sort(Sort_Random, Sort_String);

    // fill up the vote list
    for (int i; i < mapnames.Length && vctl_candidates.Length < RTV_MAPS_IN_VOTE; i++) {
        mapnames.GetString(i, map, sizeof(map));
        if (vctl_candidates.FindString(map) == -1) // another dedupe
            vctl_candidates.PushString(map);
    }
    delete mapnames;
    // shuffle one last time
    vctl_candidates.Sort(Sort_Random, Sort_String);

    // initialize vote
    Menu menu = new Menu(UntieredMenuHandler);
    int options = vctl_candidates.Length + RenderMenuHead(menu);
    menu.SetTitle("Choose the next map\n(You can /revote)\n ");
    for (int i; i < vctl_candidates.Length; i++) {
        char key[12];
        FormatEx(key, sizeof(key), ":item:%d", i);
        vctl_candidates.GetString(i, buffer, sizeof(buffer));
        menu.AddItem(key, buffer);
    }
    if (cvar_randompick.BoolValue) {
        options += 1;
        AddRandomOption(menu);
    }
    menu.Pagination         = (options <= 9) ? MENU_NO_PAGINATION : 7;
    menu.ExitButton         = true;
    menu.VoteResultCallback = UntieredVoteHandler;
    menu.DisplayVoteToAll(UNTIERED_VOTETIME);
}

int UntieredMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_VoteCancel) {
        if (param1 == VoteCancel_NoVotes) {
            PickRandomMap(vctl_candidates);
            HandleMapVoteResult();
        } else {
            rtv_state = RTV_NOT_VOTED;
        }
    } else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

void UntieredVoteHandler(Menu menu, int num_votes, int num_clients, const int client_info[][2], int num_items, const int item_info[][2])
{
    // this should not happen as the vote handler if for success
    if (num_clients == 0 || num_items == 0) {
        LogError("[LazyMapVote] Vote result without items (Untiered)");
        rtv_state = RTV_ERROR;
        return;
    }

    // recycle logic here, dont forget to fix voted_group in post if unset
    Tier2VoteHandler(menu, num_votes, num_clients, client_info, num_items, item_info);
}

static void TriggerVoteTier1()
{
    // make sure we have clients to vote
    if (CountClientsForVote() == 0) {
        PickRandomMap();
        HandleMapVoteResult();
        return;
    }

    if (rtv_state > RTV_NOT_VOTED) {
        PrintToChatAll(CHAT_PREFIX... "Vote state improper (%d)", rtv_state);
        return;    // somehow we already voted (e.g. timer)
    }
    if (groupnames.Length == 0) {
        // we can't vote from 0 groups
        LogError("[LazyMapVote] No groups to vote from in Tier1");
        rtv_state = RTV_ERROR;
        return;
    } else if (groupnames.Length == 1) {
        // special case, we don't want to use groups
        groupnames.GetString(0, voted_group, sizeof(voted_group));
        TriggerVoteTier2();
        return;
    }
    rtv_state = RTV_TIER1_RUNNING;

    char buffer[64];
    MapGroup group;
    vctl_candidates.Clear();
    // collect nominations directly, add other map groups to a temporary list for filling up later
    ArrayList         keys = new ArrayList(ByteCountToCells(64));
    for (int i; i < groupnames.Length; i++) {
        groupnames.GetString(i, buffer, sizeof(buffer));
        mapgroups.GetArray(buffer, group, sizeof(MapGroup));

        if (nominations.FindString(buffer, NominationEntry::group) >= 0) {
            // nominated: immediately add
            vctl_candidates.PushString(buffer);
        } else if (group.nominateFlags == 0 && keys.FindString(buffer) == -1) {
            // guard: no admin flag required and group not yet added
            keys.PushString(buffer);
        }
    }
    // add random map groups until we have our desired group count
    // safely terminating way is to copy and shuffle, then pull linear
    keys.Sort(Sort_Random, Sort_String);
    // now fill the candidates
    for (int i; vctl_candidates.Length < RTV_GROUPS_IN_VOTE && i < keys.Length; i++) {
        keys.GetString(i, buffer, sizeof(buffer));
        if (vctl_candidates.FindString(buffer) == -1) {
            vctl_candidates.PushString(buffer);
        }
    }
    delete keys;
    // shuffle again
    vctl_candidates.Sort(Sort_Random, Sort_String);

    // initialize vote
    Menu menu = new Menu(Tier1MenuHandler, MENU_ACTIONS_DEFAULT);
    int options = vctl_candidates.Length + RenderMenuHead(menu);
    menu.SetTitle("Choose a map group\n(You can /revote)\n ");
    for (int i; i < vctl_candidates.Length; i++) {
        char key[12];
        FormatEx(key, sizeof(key), ":item:%d", i);
        vctl_candidates.GetString(i, buffer, sizeof(buffer));
        menu.AddItem(key, buffer);
    }
    if (cvar_randompick.BoolValue) {
        options += 1;
        AddRandomOption(menu);
    }
    menu.Pagination         = (options <= 9) ? MENU_NO_PAGINATION : 7;
    menu.ExitButton         = true;
    menu.VoteResultCallback = Tier1VoteHandler;
    menu.DisplayVoteToAll(TIER1_VOTETIME);
}

int Tier1MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_VoteCancel) {
        if (param1 == VoteCancel_NoVotes) {
            if (PickRandomGroup()) {
                PrintToChatAll(CHAT_PREFIX... "Picking a group at random!");
                TriggerVoteTier2();
            } else {
                PickRandomMap();
                HandleMapVoteResult();
            }
        } else {
            // vote was cancelled, allow voting again, if no nextmap is set
            if (rtv_state < RTV_VOTE_COMPLETE)
                rtv_state = RTV_NOT_VOTED;
        }
    } else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

void Tier1VoteHandler(Menu menu, int num_votes, int num_clients, const int client_info[][2], int num_items, const int item_info[][2])
{
    // this should not happen as the vote handler if for success
    if (num_clients == 0 || num_items == 0) {
        LogError("[LazyMapVote] Vote result without items (Tier 1)");
        rtv_state = RTV_ERROR;
        return;
    }

    // we only really care about the winning item
    char buffer[64];
    menu.GetItem(item_info[0][VOTEINFO_ITEM_INDEX], buffer, sizeof(buffer));

    if (StrEqual(buffer, INFO_PICKRANDOM)) {
        if (PickRandomGroup()) {
            PrintToChatAll(CHAT_PREFIX... "Picking a group at random!");
        } else {
            PickRandomMap();
            HandleMapVoteResult();
            return;
        }
    }

    int item = StringToInt(buffer[6]); // offset 6 to strip prefix :item:
    vctl_candidates.GetString(item, voted_group, sizeof(voted_group));
    // voted group now holds the winner, run tier 2
    TriggerVoteTier2();
}

static void TriggerVoteTier2()
{
    // make sure we have clients to vote
    if (CountClientsForVote() == 0) {
        PickRandomMap();
        HandleMapVoteResult();
        return;
    }

    rtv_state = RTV_TIER2_RUNNING;
    MapGroup group;
    if (!mapgroups.GetArray(voted_group, group, sizeof(MapGroup))) {
        LogError("[LazyMapVote] Can't find voted for group in Tier2");
        rtv_state = RTV_ERROR;
        return;
    }
    vctl_candidates.Clear();
    char buffer[64];
    if (group.maps.Size == 0) {
        LogError("No maps in vote group %s ; Locking up LMV until map change", voted_group);
        rtv_state = RTV_ERROR;
        return;
    }

    // collect step 1: all nominated maps in this group definitely get in
    // at the same time we construct the copy to shuffle and fill the rest from
    ArrayList         mapnames = new ArrayList(ByteCountToCells(64));
    StringMapSnapshot snap     = group.maps.Snapshot();
    MapEntry          entry;
    for (int i; i < snap.Length; i++) {
        snap.GetKey(i, buffer, sizeof(buffer));
        group.maps.GetArray(buffer, entry, sizeof(MapEntry));

        if (nominations.FindString(buffer, NominationEntry::map) >= 0) {
            // nominated: immediately add
            if (vctl_candidates.FindString(buffer) == -1) {
                vctl_candidates.PushString(buffer);
            }
        } else if (entry.nominateFlags == 0 && mapnames.FindString(buffer) == -1) {
            // guards: map does not require admin flags and was not already added
            // not nominated, maybe random strikes
            mapnames.PushString(buffer);
        }
    }
    delete snap;
    // fill candidates until we have all the maps we want.
    int invote = group.mapsInvote;
    if (invote <= 0) invote = RTV_MAPS_IN_VOTE;
    if (mapnames.Length > 0) {
        mapnames.Sort(Sort_Random, Sort_String);
        int maxPicks = group.mapsInvote;
        if (maxPicks <= 0) maxPicks = RTV_MAPS_IN_VOTE; // fill some maps even if maps_invote is not set
        for (int i; vctl_candidates.Length < maxPicks && i < mapnames.Length; i++) {
            mapnames.GetString(i, buffer, sizeof(buffer));
            if (vctl_candidates.FindString(buffer) == -1) // another dedupe guard
                vctl_candidates.PushString(buffer);
        }
    }
    delete mapnames;
    // shuffle again
    vctl_candidates.Sort(Sort_Random, Sort_String);

    // initialize vote
    Menu menu = new Menu(Tier2MenuHandler, MENU_ACTIONS_DEFAULT);
    int options = vctl_candidates.Length + RenderMenuHead(menu);
    menu.SetTitle("Choose %s map\n(You can /revote)\n ", voted_group);
    for (int i; i < vctl_candidates.Length; i++) {
        char key[12];
        FormatEx(key, sizeof(key), ":item:%d", i);
        vctl_candidates.GetString(i, buffer, sizeof(buffer));
        menu.AddItem(key, buffer);
    }
    if (cvar_randompick.BoolValue) {
        options += 1;
        AddRandomOption(menu);
    }
    // If we paginate, a multiple of 7 looks nicest, 10 fit otherwise
    menu.Pagination         = (options <= 9) ? MENU_NO_PAGINATION : 7;
    menu.ExitButton         = true;
    menu.VoteResultCallback = Tier2VoteHandler;
    menu.DisplayVoteToAll(TIER2_VOTETIME);
}

int Tier2MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_VoteCancel) {
        if (param1 == VoteCancel_NoVotes) {
            PickRandomMap(vctl_candidates);
            HandleMapVoteResult();
        } else {
            // vote was cancelled, allow voting again, if no nextmap is set
            if (rtv_state < RTV_VOTE_COMPLETE)
                rtv_state = RTV_NOT_VOTED;
        }
    } else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

void Tier2VoteHandler(Menu menu, int num_votes, int num_clients, const int client_info[][2], int num_items, const int item_info[][2])
{
    // this should not happen as the vote handler if for success
    if (num_clients == 0 || num_items == 0) {
        LogError("[LazyMapVote] Vote result without items (Tier 2)");
        rtv_state = RTV_ERROR;
        return;
    }

    VoteHelper tmp;
    ArrayList  winners    = new ArrayList(sizeof(VoteHelper));
    int        most_votes = item_info[0][VOTEINFO_ITEM_VOTES];
    bool       firstIsRandom = false;

    // collect winners
    menu.GetItem(item_info[0][VOTEINFO_ITEM_INDEX], tmp.index, sizeof(VoteHelper::index), _, tmp.display, sizeof(VoteHelper::display));
    if (StrEqual(tmp.index, INFO_PICKRANDOM)) {
        firstIsRandom = true;
    } else {
        // this gets the full map name, in case it was cut off, so it's fine if we only do this if we have a numeric index
        int item = StringToInt(tmp.index[6]); // offset 6 to strip prefix :item:
        vctl_candidates.GetString(item, tmp.display, sizeof(VoteHelper::display));
    }
    winners.PushArray(tmp, sizeof(VoteHelper));
    if (num_items > 1 && cvar_tiebreaker.IntValue >= 0) {
        for (int i = 1; i < num_items; i++) {
            if (most_votes - item_info[i][VOTEINFO_ITEM_VOTES] >= cvar_tiebreaker.IntValue)
                break;
            menu.GetItem(item_info[i][VOTEINFO_ITEM_INDEX], tmp.index, sizeof(VoteHelper::index), _, tmp.display, sizeof(VoteHelper::display));
            int number;
            if (StringToIntEx(tmp.index[6], number)>0 && number > 0)
                vctl_candidates.GetString(number, tmp.display, sizeof(VoteHelper::display));
            winners.PushArray(tmp, sizeof(VoteHelper));
        }
    }

    if (winners.Length == 1) {
        if (firstIsRandom) {
            PrintToChatAll(CHAT_PREFIX... "Picking a map at random!");
            PickRandomMap();
        } else {
            strcopy(voted_map, sizeof(voted_map), tmp.display);    // tmp was not touched again
        }
        delete winners;
        HandleMapVoteResult();
        return;
    }

    Menu submenu = new Menu(TieBreakMenuHandler);
    submenu.SetTitle("TIE BREAKER\n(You can /revote)\n ");
    for (int i = 0; i < winners.Length && i < TIEBREAK_MAX_ENTRIES; i++) {
        winners.GetArray(i, tmp, sizeof(VoteHelper));
        submenu.AddItem(tmp.index, tmp.display);
    }
    delete winners;
    submenu.Pagination         = MENU_NO_PAGINATION;
    submenu.ExitButton         = true;
    submenu.VoteResultCallback = TieBreakVoteHandler;
    submenu.DisplayVoteToAll(TIEBREAK_VOTETIME);
}

int TieBreakMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_VoteCancel) {
        if (param1 == VoteCancel_NoVotes) {
            PickRandomMap(vctl_candidates);
            HandleMapVoteResult();
        } else {
            // vote was cancelled, allow voting again, if no nextmap is set
            if (rtv_state < RTV_VOTE_COMPLETE)
                rtv_state = RTV_NOT_VOTED;
        }
    } else if (action == MenuAction_End) {
        delete menu;
    }
    return 0;
}

void TieBreakVoteHandler(Menu menu, int num_votes, int num_clients, const int client_info[][2], int num_items, const int item_info[][2])
{
    // this should not happen as the vote handler if for success
    if (num_clients == 0 || num_items == 0) {
        LogError("[LazyMapVote] Vote result without items (Tie Breaker)");
        rtv_state = RTV_ERROR;
        return;
    }

    // ok, now we just read the first map name and yeet it into the result handler, no second rounds here
    char buffer[64];
    menu.GetItem(item_info[0][VOTEINFO_ITEM_INDEX], buffer, sizeof(buffer));

    if (StrEqual(buffer, INFO_PICKRANDOM)) {
        PrintToChatAll(CHAT_PREFIX... "Picking a map at random!");
        PickRandomMap(vctl_candidates);
    } else {
        int item = StringToInt(buffer[6]); // offset 6 to strip prefix :item:
        vctl_candidates.GetString(item, voted_map, sizeof(voted_map));
        if (voted_group[0] == 0) FindGroupForMap(voted_map, voted_group, sizeof(voted_group));
    }
    LogMessage("[LazyMapVote] Tie breaking to %s: %s in %s", buffer, voted_map, voted_group);
    // vote done, let's go
    HandleMapVoteResult();
}

// ----- Utilities ------

char[] enum2str_RTVProgress(RTVProgress rtv) {
    char buffer[32] = "<?>";
    switch(rtv) {
        case RTV_NOT_VOTED:
            buffer = "NotVoted";
        case RTV_SCHEDULED:
            buffer = "Scheduled";
        case RTV_TIER1_RUNNING:
            buffer = "GroupVoting";
        case RTV_TIER2_RUNNING:
            buffer = "MapVoting";
        case RTV_VOTE_COMPLETE:
            buffer = "Voted";
        case RTV_TRANSITION:
            buffer = "MapChange";
        case RTV_ERROR:
            buffer = "Error";
    }
    return buffer;
}
char[] enum2str_VoteSource(VoteSource vs) {
    char buffer[32] = "<?>";
    switch(vs) {
        case Vote_NotRunning:
            buffer = "NotRunning";
        case Vote_Players:
            buffer = "PlayerRTV";
        case Vote_MapEnd:
            buffer = "MapEnding";
        case Vote_Forced:
            buffer = "Command";
        case Vote_NativeCall:
            buffer = "PluginAPI";
    }
    return buffer;
}
char[] enum2str_MapChange(MapChange mapchg) {
    char buffer[32] = "<?>";
    switch(mapchg) {
        case MapChange_Instant:
            buffer = "Instant";
        case MapChange_MapEnd:
            buffer = "MapEnd";
        case MapChange_RoundEnd:
            buffer = "RoundEnd";
    }
    return buffer;
}