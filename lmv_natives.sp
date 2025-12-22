#if !defined PLUGIN_VERSION
 #error Compiler main file!
#endif

// definitions from mapchooser
enum NominateResult
{
	Nominate_Added,         /** The map was added to the nominate list */
	Nominate_Replaced,      /** A clients existing nomination was replaced */
	Nominate_AlreadyInVote, /** Specified map was already in the vote */
	Nominate_InvalidMap,    /** Mapname specified wasn't a valid map */
	Nominate_VoteFull       /** This will only occur if force was set to false */
};
enum MapChange
{
	MapChange_Instant=0,      /** Change map as soon as the voting results have come in */
	MapChange_RoundEnd=1,     /** Change map at the end of the round */
	MapChange_MapEnd=2        /** Change the sm_nextmap cvar */
};

GlobalForward fwd_NominationRemoved;
GlobalForward fwd_MapVoteStarted;

void initNatives() {
    RegPluginLibrary("mapchooser");

    CreateNative("NominateMap", Native_NominateMap);
    CreateNative("RemoveNominationByMap", Native_RemoveNominationByMap);
    CreateNative("RemoveNominationByOwner", Native_RemoveNominationByOwner);
    CreateNative("GetExcludeMapList", Native_GetExcludeMapList);
    CreateNative("GetNominatedMapList", Native_GetNominatedMapList);
    CreateNative("CanMapChooserStartVote", Native_CanMapChooserStartVote);
    CreateNative("InitiateMapChooserVote", Native_InitiateMapChooserVote);
    CreateNative("HasEndOfMapVoteFinished", Native_HasEndOfMapVoteFinished);
    CreateNative("EndOfMapVoteEnabled", Native_EndOfMapVoteEnabled);

    fwd_NominationRemoved = CreateGlobalForward("OnNominationRemoved", ET_Ignore, Param_String, Param_Cell);
    fwd_MapVoteStarted = CreateGlobalForward("OnMapVoteStarted", ET_Ignore);

}

any Native_NominateMap(Handle plugin, int numParams)
{
    char buffer[64];
    GetNativeString(1, buffer, sizeof(buffer));
    //bool force = GetNativeCell(2);
    bool client = GetNativeCell(3);

    char group[64];
    if (!FindGroupForMap(buffer, group, sizeof(group))) {
        return Nominate_InvalidMap;
    }
    if (!DoClientNomination(client, group, buffer)) {
        return Nominate_AlreadyInVote;
    }
    return Nominate_Added;
}

any Native_RemoveNominationByMap(Handle plugin, int numParams)
{
    char buffer[64];
    GetNativeString(1, buffer, sizeof(buffer));

    NominationEntry entry;
    int count;
    for (int i=nominations.Length-1; i>=0; i--) {
        nominations.GetArray(i, entry, sizeof(NominationEntry));
        if (StrEqual(entry.map, buffer, false)) {
            count += 1;
            nominations.Erase(i);
            Notify_OnNominationRemoved(entry.map, GetClientOfUserId(entry.userId));
        }
    }

    return count != 0;
}

any Native_RemoveNominationByOwner(Handle plugin, int numParams)
{
    int owner = GetNativeCell(1);
    return RemoveClientNominations(owner) != 0;
}

void Native_GetExcludeMapList(Handle plugin, int numParams)
{
    ArrayList list = GetNativeCell(1);
    list.Clear();
    for (int i=0; i<RECENT_MAP_COUNT; i++) {
        if (recent_maps[i][0] != 0) {
            list.PushString(recent_maps[i]);
        }
    }
}

void Native_GetNominatedMapList(Handle plugin, int numParams) {
    ArrayList maparray = GetNativeCell(1);
    ArrayList ownerarray = GetNativeCell(2);

    char buffer[64];
    for (int i; i<nominations.Length; i++) {
        nominations.GetString(i, buffer, sizeof(buffer), NominationEntry::map);
        maparray.PushString(buffer);
        if (ownerarray != null) ownerarray.Push(0);
    }
}

any Native_CanMapChooserStartVote(Handle plugin, int numParams) {
    return rtv_state <= RTV_SCHEDULED;
}

void Native_InitiateMapChooserVote(Handle plugin, int numParams) {
    MapChange when = GetNativeCell(1);
    // ArrayList inputarray = GetNativeCell(2);

    // we are not handling map input
    TriggerVote(Vote_NativeCall, when);
}

any Native_HasEndOfMapVoteFinished(Handle plugin, int numParams) {
    return rtv_state >= RTV_VOTE_COMPLETE && vote_source == Vote_MapEnd;
}
any Native_EndOfMapVoteEnabled(Handle plugin, int numParams) {
    return true;
}

void Notify_OnNominationRemoved(const char[] map, int owner)
{
    Call_StartForward(fwd_NominationRemoved);
    Call_PushString(map);
    Call_PushCell(owner);
    Call_Finish();
}

void Notify_OnMapVoteStarted()
{
    Call_StartForward(fwd_MapVoteStarted);
    Call_Finish();
}