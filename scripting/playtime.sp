#include <sourcemod>
#include <cstrike>
#include <colors_csgo_v2>

#pragma semicolon 1
#pragma newdecls required

/*********************************
 *  Plugin Information
 *********************************/
#define PLUGIN_VERSION "1.10"

public Plugin myinfo =
{
  name = "Playtime",
  author = "Invex | Byte",
  description = "Counts and stores player playtime.",
  version = PLUGIN_VERSION,
  url = "https://invex.gg"
};

/*********************************
 *  Definitions
 *********************************/
#define CHAT_TAG_PREFIX "[{orange}PlayTime{default}] "
#define ANTI_FLOOD_TIME 1.0
#define TOP100_UPDATE_TIME 900
#define MAX_MENU_OPTIONS 6

/*********************************
 *  Globals
 *********************************/

//Playtime counters
int g_PlayTimeSessionCt[MAXPLAYERS+1] = {0, ...}; //playtime in current session in minutes on CT side
int g_PlayTimeSessionT[MAXPLAYERS+1] = {0, ...}; //playtime in current session in minutes on T side
int g_PlayTimeCurrentServerCt[MAXPLAYERS+1] = {0, ...}; //playtime on server (cached from db) in minutes on CT side
int g_PlayTimeCurrentServerT[MAXPLAYERS+1] = {0, ...}; //playtime on server (cached from db) in minutes on T side
int g_PlayTimeAllServerCt[MAXPLAYERS+1] = {0, ...}; //playtime on all servers (cached from db) in minutes on CT side
int g_PlayTimeAllServerT[MAXPLAYERS+1] = {0, ...}; //playtime on all server (cached from db) in minutes on T side

//Misc
bool g_CanCheckPlayTime[MAXPLAYERS+1] = {true, ...}; //for anti-flood
char g_Top100Names[100][64];
int g_Top100PlayTime[100] = {0, ...};
int g_Top100LastUpdated = -1;

//ConVars
ConVar g_Cvar_PlayTimeServerId = null;

//Lateload
bool g_LateLoaded = false;

/*********************************
 *  Forwards
 *********************************/

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
  CreateNative("GetClientPlayTime", Native_GetClientPlayTime);
  CreateNative("GetClientPlayTimeAll", Native_GetClientPlayTimeAll);

  g_LateLoaded = late;
  return APLRes_Success;
}

// Plugin Start
public void OnPluginStart()
{
  //Common translations
  LoadTranslations("common.phrases");
  
  //Flags
  CreateConVar("sm_playtime_version", PLUGIN_VERSION, "", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_CHEAT|FCVAR_DONTRECORD);
  
  //Convars
  g_Cvar_PlayTimeServerId = CreateConVar("sm_playtime_serverid", "0", "Servers ID in database");
  
  //Commands
  RegConsoleCmd("sm_playtime", Command_CheckPlayTime);
  RegConsoleCmd("sm_pt", Command_CheckPlayTime);
  
  RegConsoleCmd("sm_playtimeall", Command_CheckPlayTimeAll);
  RegConsoleCmd("sm_ptall", Command_CheckPlayTimeAll);
  
  RegConsoleCmd("sm_playtimetop", Command_CheckPlayTimeTop);
  RegConsoleCmd("sm_pttop", Command_CheckPlayTimeTop);
  
  RegAdminCmd("sm_playtimecheck", Command_AdminCheckPlayTime, ADMFLAG_GENERIC);
  RegAdminCmd("sm_ptcheck", Command_AdminCheckPlayTime, ADMFLAG_GENERIC);
  
  RegAdminCmd("sm_playtimecheckall", Command_AdminCheckPlayTimeAll, ADMFLAG_GENERIC);
  RegAdminCmd("sm_ptcheckall", Command_AdminCheckPlayTimeAll, ADMFLAG_GENERIC);
  
  //Enable checking
  for (int i = 1; i <= MaxClients; ++i) {
    if(IsClientInGame(i)) {
      g_CanCheckPlayTime = true;
    }
  }
  
  //Create config file
  AutoExecConfig(true, "playtime");
  
  //Late load
  if (g_LateLoaded) {
    for (int i = 1; i <= MaxClients; ++i) {
      if (IsClientInGame(i)) {
        OnClientPutInServer(i);

        if (IsClientAuthorized(i)) {
          char steamId[32];
          if (!GetClientAuthId(i, AuthId_Steam2, steamId, sizeof(steamId))) {
            LogError("Could not get client auth ID during late load");
          }
          else {
            OnClientAuthorized(i, steamId);
          }
        }
      }
    }
  }
  
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

public void OnClientPutInServer(int client)
{
  if(IsFakeClient(client))
    return;
    
  //Reset current session playtime for new client
  g_PlayTimeSessionCt[client] = 0;
  g_PlayTimeSessionT[client] = 0;
}

//Insert ignore into database to ensure entry exists for playtime for current server
public void OnClientAuthorized(int client, const char[] steamId)
{
  if(IsFakeClient(client))
    return;
  
  //Query database
  char error[255];
  Handle db = SQL_Connect("playtime", true, error, sizeof(error));
   
  if (db == null) {
    PrintToServer("Could not connect: %s", error);
  }
  else {
    //Connection successful
    
    //Create pack for next query
    DataPack pack = new DataPack();
    pack.WriteCell(client);
    pack.WriteString(steamId);

    //Get client name and escape
    char clientName[255];
    GetClientName(client, clientName, sizeof(clientName));
    SQL_EscapeString(db, clientName, clientName, sizeof(clientName));
    
    //Insert ignore to ensure client has entry for this server
    char query[1024];
    Format(query, sizeof(query), "INSERT IGNORE INTO pt_times(authid, name, ServerID) VALUES ('%s', '%s', %d)", steamId, clientName, g_Cvar_PlayTimeServerId.IntValue);
    SQL_TQuery(db, DB_Callback_OnClientAuthorized, query, pack);
    
    delete db;
  }
}

//Cache playtime from DB once we are sure at least one entry exists for current server (thanks to previous insert ignore)
public void DB_Callback_OnClientAuthorized(Handle owner, Handle hndl, const char[] error, DataPack pack)
{
  if (hndl == null) {
    LogError("Error updating play time at OnClientAuthorized: %s", error);
  } 
  else {
    pack.Reset();

    int client = pack.ReadCell();
    char steamId[32];
    pack.ReadString(steamId, sizeof(steamId));

    char dbError[255];
    Handle db = SQL_Connect("playtime", true, dbError, sizeof(dbError));
    if (db == null) {
        PrintToServer("Could not connect: %s", dbError);
    } else {
      //Cache current/all server total play time
      char query[1024];
      Format(query, sizeof(query), "(SELECT SUM(playtime_ct), SUM(playtime_t), 'all' as type FROM pt_times WHERE authid = '%s' LIMIT 1) UNION (SELECT SUM(playtime_ct), SUM(playtime_t), 'current' as type FROM pt_times WHERE authid = '%s' AND ServerID = %d LIMIT 1)", steamId, steamId, g_Cvar_PlayTimeServerId.IntValue);
      SQL_TQuery(db, DB_Callback_CachePlayTime, query, client);

      delete db;
    }
  }

  delete pack;
}

public void DB_Callback_CachePlayTime(Handle owner, Handle hndl, const char[] error, int client)
{
  if (hndl == null) {
    LogError("Error caching playtime in DB_Callback_CachePlayTime: %s", error);
  }
  else {
    int iRowCount = SQL_GetRowCount(hndl);
    if (iRowCount) {
      while (SQL_FetchRow(hndl)) {
        char type[32];
        int dbPlayTimeCt = SQL_FetchInt(hndl, 0);
        int dbPlayTimeT = SQL_FetchInt(hndl, 1);
        SQL_FetchString(hndl, 2, type, sizeof(type));

        if (StrEqual(type, "all")) {
          g_PlayTimeAllServerCt[client] = dbPlayTimeCt;
          g_PlayTimeAllServerT[client] = dbPlayTimeT;
        }
        else if (StrEqual(type, "current")) {
          g_PlayTimeCurrentServerCt[client] = dbPlayTimeCt;
          g_PlayTimeCurrentServerT[client] = dbPlayTimeT;
        }
        else {
          LogError("Invalid playtime retrieved from database in DB_Callback_CachePlayTime");
        }
      }
    }
  }
}

//Cache top100 playtimes
public void DB_Callback_CachePlayTimeTop(Handle owner, Handle hndl, const char[] error, int client)
{
  if (hndl == null) {
    LogError("Error selecting play time at Command_CheckPlayTimeTop: %s", error);
  }
  else {
    int iRowCount = SQL_GetRowCount(hndl);
    if (iRowCount) {
      int i = 0; //counter
      while (SQL_FetchRow(hndl)) {
        char name[64];
        SQL_FetchString(hndl, 0, name, sizeof(name));
        
        //Check for empty name
        if (StrEqual(name, ""))
          Format(name, sizeof(name), "N/A");
        
        Format(g_Top100Names[i], sizeof(g_Top100Names[]), name);
        g_Top100PlayTime[i] = SQL_FetchInt(hndl, 1);
        
        ++i;
      }
      
      //Display menu
      ShowTop100Menu(client);
    }
  }
}


//Write changed to database on disconnect
//We only need to add the current session time to the playtime stored for this server
public void OnClientDisconnect(int client)
{
  if(IsFakeClient(client))
    return;
  
  //Write changes to database for current session
  char steamId[32];
  if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId))) {
    LogError("Could not get client auth ID at OnClientDisconnect");
    return;
  }
  
  //Query database
  char error[255];
  Handle db = SQL_Connect("playtime", true, error, sizeof(error));
   
  if (db == null) {
    PrintToServer("Could not connect: %s", error);
  } else {
    //Connection successful
    
    //Get client name and escape
    char clientName[255];
    GetClientName(client, clientName, sizeof(clientName));
    SQL_EscapeString(db, clientName, clientName, sizeof(clientName));

    //Add current session time to current servers stored playtime
    //Also update latest client name
    char query[1024];
    Format(query, sizeof(query), "UPDATE pt_times SET playtime_ct=playtime_ct+%d, playtime_t=playtime_t+%d, name='%s' WHERE authid = '%s' AND ServerID = %d", g_PlayTimeSessionCt[client], g_PlayTimeSessionT[client], clientName, steamId, g_Cvar_PlayTimeServerId.IntValue);
    SQL_TQuery(db, DB_Callback_OnClientDisconnect, query, _);

    delete db;
  }
}

public void DB_Callback_OnClientDisconnect(Handle owner, Handle hndl, const char[] error, any data)
{
  if (hndl == null)
    LogError("Error updating play time at OnClientDisconnect: %s", error);
}


/*********************************
 *  Commands
 *********************************/

public Action Command_AdminCheckPlayTime(int client, int args)
{
  //Get arguments
  if (args != 1 && args != 2) {
    char cmd[32];
    GetCmdArg(0, cmd, sizeof(cmd));
    CPrintToChat(client, "%sUsage: %s <player> or %s <player> <CT|T>.", CHAT_TAG_PREFIX, cmd, cmd);
    return Plugin_Handled;
  }
  
  char team[3];
  char targetstring[64];
  
  GetCmdArg(1, targetstring, sizeof(targetstring));
  GetCmdArg(2, team, sizeof(team));
  
  int target = FindTarget(client, targetstring, true, false);
  
  if (target == -1)
    return Plugin_Handled;
  
  TriggerPlaytime(client, target, team, true);
  
  return Plugin_Handled;
}

public Action Command_AdminCheckPlayTimeAll(int client, int args)
{
  //Get arguments
  if (args != 1 && args != 2) {
    char cmd[32];
    GetCmdArg(0, cmd, sizeof(cmd));
    CPrintToChat(client, "%sUsage: %s <player> or %s <player> <CT|T>.", CHAT_TAG_PREFIX, cmd, cmd);
    return Plugin_Handled;
  }
  
  char team[3];
  char targetstring[64];
  
  GetCmdArg(1, targetstring, sizeof(targetstring));
  GetCmdArg(2, team, sizeof(team));
  
  int target = FindTarget(client, targetstring, true, false);
  
  if (target == -1)
    return Plugin_Handled;
  
  TriggerPlaytime(client, target, team, false);
  
  return Plugin_Handled;
}

public Action Command_CheckPlayTime(int client, int args)
{
  if (args > 1) {
    char cmd[32];
    GetCmdArg(0, cmd, sizeof(cmd));
    CPrintToChat(client, "%sUsage: %s or %s <CT|T>.", CHAT_TAG_PREFIX, cmd, cmd);
    return Plugin_Handled;
  }
  
  char team[3];
  GetCmdArg(1, team, sizeof(team));
  
  TriggerPlaytime(client, client, team, true);
  
  return Plugin_Handled;
}

public Action Command_CheckPlayTimeAll(int client, int args)
{
  if (args > 1) {
    char cmd[32];
    GetCmdArg(0, cmd, sizeof(cmd));
    CPrintToChat(client, "%sUsage: %s or %s <CT|T>.", CHAT_TAG_PREFIX, cmd, cmd);
    return Plugin_Handled;
  }
  
  char team[3];
  GetCmdArg(1, team, sizeof(team));
  
  TriggerPlaytime(client, client, team, false);
  
  return Plugin_Handled;
}

public Action Command_CheckPlayTimeTop(int client, int args)
{
  //See if we can show using cached results or if we need to update
  if (GetTime() - g_Top100LastUpdated <= TOP100_UPDATE_TIME) {
    ShowTop100Menu(client);
  } else {
    //We need to query database
    char error[255];
    Handle db = SQL_Connect("playtime", true, error, sizeof(error));
    
    if (db == null) {
      PrintToServer("Could not connect: %s", error);
    } else {
      //Connection successful
      g_Top100LastUpdated = GetTime();
      
      char query[1024];
      Format(query, sizeof(query), "SELECT name, playtime_ct + playtime_t as playtime FROM pt_times WHERE ServerID = %d ORDER BY playtime DESC LIMIT 100", g_Cvar_PlayTimeServerId.IntValue);
      
      SQL_TQuery(db, DB_Callback_CachePlayTimeTop, query, client);

      delete db;
    }
  }
  
  return Plugin_Handled;
}

/*********************************
 *  Timers
 *********************************/
 
//Update local time played variables
public Action CheckTime(Handle timer)
{
  //For every player
  for (int i = 1; i <= MaxClients; ++i) {
    if (IsClientInGame(i)) {
      if (GetClientTeam(i) == CS_TEAM_T)
        ++g_PlayTimeSessionT[i];
      else if (GetClientTeam(i) == CS_TEAM_CT)
        ++g_PlayTimeSessionCt[i];
    }
  }
  
  return Plugin_Continue;
}

//Re-enable playtime checking usage for particular client
public Action Timer_ReEnable_Usage(Handle timer, int client)
{
  g_CanCheckPlayTime[client] = true;
}

/*********************************
 *  Menus And Handlers
 *********************************/

public int Top100MenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
  switch (action)
  {
    case MenuAction_DisplayItem:
    {
      //Kind of hacky, reset the menu title only if its first item of each page
      //This is so we only 'refresh' the title once per menu page
      if (param2 % MAX_MENU_OPTIONS == 0) {
        char titleString[1024];
        Format(titleString, sizeof(titleString), "Top 100 PlayTime:\n ");
        
        //Show 10 entries per page
        int min = (param2 / 6) * 10;
        int max = min + 10;
        if (max > sizeof(g_Top100PlayTime))
          max = sizeof(g_Top100PlayTime);
        
        for (int i = min; i < max; ++i) {
          Format(titleString, sizeof(titleString), "%s\n%d. %s (%d min)", titleString, i+1, g_Top100Names[i], g_Top100PlayTime[i]);
        }
        
        menu.SetTitle(titleString);
      }
    }
    
    case MenuAction_End:
    {
      delete menu;
    }
  }
}


/*********************************
 *  Helper Functions / Other
 *********************************/

//Perform Playtime check
public void TriggerPlaytime(int client, int target, char team[3], bool currentServerOnly)
{
  if(IsFakeClient(target))
    return;
    
  if (!IsClientInGame(target))
    return;

  if (!g_CanCheckPlayTime[client]) {
    //Using plugin too quickly
    CPrintToChat(client, "%s%s", CHAT_TAG_PREFIX, "You are using this command too quickly.");
    LogAction(client, -1, "\"%L\" is using !playtime too quickly. Possible flood attempt.", client);
    return;
  }

  g_CanCheckPlayTime[client] = false;
  CreateTimer(ANTI_FLOOD_TIME, Timer_ReEnable_Usage, client);
  
  if (strlen(team) != 0 && !StrEqual(team, "CT", false) && !StrEqual(team, "T", false)) {
    CPrintToChat(client, "%sTeam must be either {lightblue}CT{default} or {yellow}T{default}.", CHAT_TAG_PREFIX);
    return;
  }
  
  //Get computed total playtime
  int totalPlayTimeCt = g_PlayTimeSessionCt[target];
  int totalPlayTimeT = g_PlayTimeSessionT[target];

  if (currentServerOnly) {
    totalPlayTimeCt += g_PlayTimeCurrentServerCt[target];
    totalPlayTimeT += g_PlayTimeCurrentServerT[target];
  }
  else {
    totalPlayTimeCt += g_PlayTimeAllServerCt[target];
    totalPlayTimeT += g_PlayTimeAllServerT[target];
  }

  //Set server text
  char serverText[12];
  Format(serverText, sizeof(serverText), "this server");
  if (!currentServerOnly)
    Format(serverText, sizeof(serverText), "all servers");

  //Print out users playtime
  if (strlen(team) == 0) { //both teams
    CPrintToChatAll("%s{lime}%N's{default} total play time for {lime}%s{default} is {lime}%d{default} minutes.", CHAT_TAG_PREFIX, client, serverText, totalPlayTimeCt + totalPlayTimeT);
  }
  else if (StrEqual(team, "CT", false)) {
    CPrintToChatAll("%s{lime}%N's{default} play time on {lightblue}CT{default} for {lime}%s{default} is {lime}%d{default} minutes.", CHAT_TAG_PREFIX, client, serverText, totalPlayTimeCt);
  }
  else if (StrEqual(team, "T", false)) {
    CPrintToChatAll("%s{lime}%N's{default} play time on {yellow}T{default} for {lime}%s{default} is {lime}%d{default} minutes.", CHAT_TAG_PREFIX, client, serverText, totalPlayTimeT);
  }
}

void ShowTop100Menu(int client)
{
  if (IsFakeClient(client) || !IsClientInGame(client))
    return;
  
  //Create a menu
  Menu top100Menu = new Menu(Top100MenuHandler, MenuAction_Select|MenuAction_Cancel|MenuAction_End|MenuAction_DisplayItem);
  
  //Need dummy items or else menu wont show correct pagination
  //Need 10 pages total
  for (int i = 0; i < MAX_MENU_OPTIONS * 10; ++i)
    top100Menu.AddItem("", "", ITEMDRAW_NOTEXT);
  
  top100Menu.Display(client, MENU_TIME_FOREVER);
}

/*********************************
 *  Natives
 *********************************/

public int Native_GetClientPlayTime(Handle plugin, int numParams)
{
  int client = GetNativeCell(1);
  int team = GetNativeCell(2);
  
  return GetCachedPlayTime(client, team, true);
}

public int Native_GetClientPlayTimeAll(Handle plugin, int numParams)
{
  int client = GetNativeCell(1);
  int team = GetNativeCell(2);
  
  return GetCachedPlayTime(client, team, false);
}

//Non threaded retrieval of playtime from database
int GetCachedPlayTime(int client, int team, bool currentServerOnly)
{
  if (client <= 0 || client > MaxClients) {
    ThrowNativeError(SP_ERROR_NATIVE, "Client is not valid");
    return -1;
  }
  
  if (!IsClientInGame(client)) {
    ThrowNativeError(SP_ERROR_NATIVE, "Client is not in game");
    return -1;
  }
  
  if (IsFakeClient(client)) {
    ThrowNativeError(SP_ERROR_NATIVE, "Cannot get playtime of Fake Clients");
    return -1;
  }

  if (!IsClientAuthorized(client)) {
    ThrowNativeError(SP_ERROR_NATIVE, "Client has not been authorized");
    return -1;
  }
  
  if (team != CS_TEAM_NONE && team != CS_TEAM_T && team != CS_TEAM_CT) {
    ThrowNativeError(SP_ERROR_NATIVE, "Invalid team provided");
    return -1;
  }
  
  //Get client Auth ID
  char steamId[32];
  if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId))) {
    ThrowNativeError(SP_ERROR_NATIVE, "Failed to get client Auth ID");
    return -1;
  }

  //Get computed total playtime
  int totalPlayTimeCt = g_PlayTimeSessionCt[client];
  int totalPlayTimeT = g_PlayTimeSessionT[client];

  if (currentServerOnly) {
    totalPlayTimeCt += g_PlayTimeCurrentServerCt[client];
    totalPlayTimeT += g_PlayTimeCurrentServerT[client];
  }
  else {
    totalPlayTimeCt += g_PlayTimeAllServerCt[client];
    totalPlayTimeT += g_PlayTimeAllServerT[client];
  }

  if (team == CS_TEAM_NONE) { //both teams
    return totalPlayTimeCt + totalPlayTimeT;
  }
  else if (team == CS_TEAM_CT) {
    return totalPlayTimeCt;
  }
  else if (team == CS_TEAM_T) {
    return totalPlayTimeT;
  }

  return -1;
}