#include <sourcemod>
#include <cstrike>
#include "colors_csgo.inc"

//Defines
#define VERSION "1.01"
#define CHAT_TAG_PREFIX "[{orange}PlayTime{default}] "

#define ANTI_FLOOD_TIME 1.0

//Global Varibales
int ServerID = 0;
int playtime_ct[MAXPLAYERS+1] = {0, ...}; //playtime in current session in minutes on CT side
int playtime_t[MAXPLAYERS+1] = {0, ...}; //playtime in current session in minutes on T side

bool g_canCheckPlayTime[MAXPLAYERS+1] = {true, ...}; //for anti-flood

//Convars
ConVar cvar_playtime_serverID = null;

public Plugin myinfo =
{
  name = "Playtime Counter",
  author = "Invex | Byte",
  description = "Counts and stores player playtime.",
  version = VERSION,
  url = "http://www.invexgaming.com.au"
};

// Plugin Start
public void OnPluginStart()
{
  //Common translations
  LoadTranslations("common.phrases");
  
  //Flags
  CreateConVar("sm_playtime_version", VERSION, "", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_CHEAT|FCVAR_DONTRECORD);
  
  //Convars
  cvar_playtime_serverID = CreateConVar("sm_playtime_serverid", "0", "Servers ID in database");
  
  //Commands
  RegConsoleCmd("sm_playtime", Command_CheckPlayTime);
  RegConsoleCmd("sm_pt", Command_CheckPlayTime);
  
  RegAdminCmd("sm_checkplaytime", Command_AdminCheckPlayTime, ADMFLAG_GENERIC);
  RegAdminCmd("sm_checkpt", Command_AdminCheckPlayTime, ADMFLAG_GENERIC);
  
  //Hook serverID
  HookConVarChange(cvar_playtime_serverID, ConVarChange);
  
  //Enable checking
  for (int i = 1; i <= MaxClients; ++i) {
    if(IsClientInGame(i)) {
      g_canCheckPlayTime = true;
    }
  }
  
  //Create config file
  AutoExecConfig(true, "playtime");
  
  //Set server ID
  ServerID = GetConVarInt(cvar_playtime_serverID);
  
  //Timer
  CreateTimer(60.0, CheckTime, _, TIMER_REPEAT);
}

//When plugin ends, call disconnect so changes are also written
public void OnPluginEnd()
{
  for (int i = 1; i <= MaxClients; ++i) {
    if(IsClientInGame(i)) {
      OnClientDisconnect(i);
    }
  }
}

public void ConVarChange(Handle convar, const char[] oldValue, const char[] newValue)
{
  ServerID = StringToInt(newValue) ;
}


public void OnClientPutInServer(int client)
{
  if(IsFakeClient(client))
    return;
    
  //Reset play time for current session
  playtime_t[client] = 0;
  playtime_ct[client] = 0;
}

//Check player in the database to see if row exists for them
//If not insert it in now
public void OnClientAuthorized(int client, const char[] SteamID)
{
  if(IsFakeClient(client))
    return;
  
  //Query database
  char error[255];
  Handle db = SQL_Connect("playtime", true, error, sizeof(error));
   
  if (db == INVALID_HANDLE) {
    PrintToServer("Could not connect: %s", error);
  } else {
    //Connection successful
    char query[255];
    Format(query, sizeof(query), "INSERT IGNORE INTO pt_times(authid, ServerID) VALUES ('%s', %d)", SteamID, ServerID);
    SQL_TQuery(db, DB_Callback_OnClientAuthorized, query, _);

    CloseHandle(db);
  }
}

public void DB_Callback_OnClientAuthorized(Handle owner, Handle hndl, const char[] error, any data)
{
  if (hndl == INVALID_HANDLE)
    LogError("Error updating play time at OnClientAuthorized: %s", error);
}

//Write changed to database on disconnect
public void OnClientDisconnect(int client)
{
  if(IsFakeClient(client))
    return;
  
  //Write changes to database for current session
  char SteamID[32];
  if (!GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID))) {
    LogError("Could not get client auth ID at OnClientDisconnect");
    return;
  }
  
  //Query database
  char error[255];
  Handle db = SQL_Connect("playtime", true, error, sizeof(error));
   
  if (db == INVALID_HANDLE) {
    PrintToServer("Could not connect: %s", error);
  } else {
    //Connection successful
    char query[255];
    Format(query, sizeof(query), "UPDATE pt_times SET playtime_ct=playtime_ct+%d, playtime_t=playtime_t+%d WHERE authid = '%s' AND ServerID = %d", playtime_ct[client], playtime_t[client], SteamID, ServerID);
    SQL_TQuery(db, DB_Callback_OnClientDisconnect, query, _);

    CloseHandle(db);
  }
}

public void DB_Callback_OnClientDisconnect(Handle owner, Handle hndl, const char[] error, any data)
{
  if (hndl == INVALID_HANDLE)
    LogError("Error updating play time at OnClientDisconnect: %s", error);
}

//Update local time played variables
public Action CheckTime(Handle timer)
{
  //For every player
  for (int i = 1; i <= MaxClients; ++i) {
    if (IsClientInGame(i)) {
      if (GetClientTeam(i) == CS_TEAM_T)
        ++playtime_t[i];
      else if (GetClientTeam(i) == CS_TEAM_CT)
        ++playtime_ct[i];
    }
  }
  
  return Plugin_Continue;
}

public Action Command_AdminCheckPlayTime(int client, int args)
{
  //Get arguments
  if (args != 1 && args != 2) {
    CPrintToChat(client, "%sUsage: sm_checkplaytime <player> or sm_checkplaytime <CT|T> <player>.", CHAT_TAG_PREFIX);
    return Plugin_Handled;
  }
  
  char team[3];
  char targetstring[64];
  
  GetCmdArg(1, targetstring, sizeof(targetstring));
  GetCmdArg(2, team, sizeof(team));
  
  int target = FindTarget(client, targetstring, true, false);
  
  if (target == -1)
    return Plugin_Handled;
  
  trigger_playtime(target, client, team);
  
  return Plugin_Handled;
}


public Action Command_CheckPlayTime(int client, int args)
{
  if (args != 0 && args != 1) {
    CPrintToChat(client, "%sUsage: sm_playtime or sm_playtime <CT|T>.", CHAT_TAG_PREFIX);
    return Plugin_Handled;
  }
  
  char team[3];
  GetCmdArg(1, team, sizeof(team));
  
  trigger_playtime(client, client, team);
  
  return Plugin_Handled;
}

/**
* Perform Playtime check
* caller param player who triggered check
*/
public void trigger_playtime(int target, int caller, char team[3])
{
  if(IsFakeClient(target))
    return;
    
  if (!IsClientInGame(target))
    return;

  if (!g_canCheckPlayTime[caller]) {
    //Using plugin too quickly
    CPrintToChat(caller, "%s%s", CHAT_TAG_PREFIX, "You are using this command too quickly.");
    LogAction(caller, -1, "\"%L\" is using !playtime too quickly. Possible flood attempt.", caller);
    return;
  }

  g_canCheckPlayTime[caller] = false;
  CreateTimer(ANTI_FLOOD_TIME, Timer_ReEnable_Usage, caller);
  
  if (strlen(team) != 0 && !StrEqual(team, "CT", false) && !StrEqual(team, "T", false)) {
    CPrintToChat(caller, "%sTeam must be either {lightblue}CT{default} or {olive}T{default}.", CHAT_TAG_PREFIX);
    return;
  }
  
  //Look up players CT time and T time
  char SteamID[32];
  if (!GetClientAuthId(target, AuthId_Steam2, SteamID, sizeof(SteamID))) {
    LogError("Could not get client auth ID at trigger_playtime");
    return;
  }
  
  //Query database
  char error[255];
  Handle db = SQL_Connect("playtime", true, error, sizeof(error));
   
  if (db == INVALID_HANDLE) {
    PrintToServer("Could not connect: %s", error);
  } else {
    //Make datapack for query
    Handle datapack = CreateDataPack();
    WritePackCell(datapack, target);
    if (strlen(team) == 0)
      WritePackCell(datapack, 0);
    else if (strlen(team) != 0) {
      if (StrEqual(team, "CT", false))
        WritePackCell(datapack, CS_TEAM_CT);
      else if (StrEqual(team, "T", false))
        WritePackCell(datapack, CS_TEAM_T);
    }
    
    //Connection successful
    char query[255];
    Format(query, sizeof(query), "SELECT playtime_ct, playtime_t FROM pt_times WHERE authid = '%s' AND ServerID = %d", SteamID, ServerID);
    SQL_TQuery(db, DB_Callback_CheckPlayTime, query, datapack);

    CloseHandle(db);
  }
}

//Re-enable playtime checking usage for particular client
public Action Timer_ReEnable_Usage(Handle timer, int client)
{
  g_canCheckPlayTime[client] = true;
}

public void DB_Callback_CheckPlayTime(Handle owner, Handle hndl, const char[] error, any datapack)
{
  if (hndl == INVALID_HANDLE) {
    LogError("Error selecting play time at Command_CheckPlayTime: %s", error);
    CloseHandle(datapack);
  }
  else {
    ResetPack(datapack);
    int client = ReadPackCell(datapack);
    int mode = ReadPackCell(datapack);
    
    int iRowCount = SQL_GetRowCount(hndl);
    if (iRowCount) {
      SQL_FetchRow(hndl);
      int db_playtime_ct = SQL_FetchInt(hndl, 0);
      int db_playtime_t = SQL_FetchInt(hndl, 1)
      
      //Print out users playtime
      if (mode == 0) { //both teams
        CPrintToChatAll("%s{lightgreen}%N's{default} total play time is {lightgreen}%d{default} minutes.", CHAT_TAG_PREFIX, client, db_playtime_ct + db_playtime_t + playtime_ct[client] + playtime_t[client]);
      }
      else if (mode == CS_TEAM_CT) {
        CPrintToChatAll("%s{lightgreen}%N's{default} play time on {lightblue}CT{default} is {lightgreen}%d{default} minutes.", CHAT_TAG_PREFIX, client, db_playtime_ct + playtime_ct[client]);
      }
      else if (mode == CS_TEAM_T) {
        CPrintToChatAll("%s{lightgreen}%N's{default} play time on {olive}T{default} is {lightgreen}%d{default} minutes.", CHAT_TAG_PREFIX, client, db_playtime_t + playtime_t[client]);
      }
    }
  }
}