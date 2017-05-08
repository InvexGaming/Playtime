#include <sourcemod>
#include <cstrike>
#include "colors_csgo.inc"

//Defines
#define VERSION "1.02"
#define CHAT_TAG_PREFIX "[{orange}PlayTime{default}] "

#define ANTI_FLOOD_TIME 1.0
#define TOP100_UPDATE_TIME 900
#define MAX_MENU_OPTIONS 6

//Global Varibales
int g_ServerId = 0;
int g_PlayTimeCt[MAXPLAYERS+1] = {0, ...}; //playtime in current session in minutes on CT side
int g_PlayTimeT[MAXPLAYERS+1] = {0, ...}; //playtime in current session in minutes on T side

bool g_CanCheckPlayTime[MAXPLAYERS+1] = {true, ...}; //for anti-flood

char g_Top100Names[100][64];
int g_Top100PlayTime[100] = {0, ...}
int g_Top100LastUpdated = -1;

//Convars
ConVar g_Cvar_PlayTimeServerId = null;

public Plugin myinfo =
{
  name = "Playtime",
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
  
  //Hook serverID
  HookConVarChange(g_Cvar_PlayTimeServerId, ConVarChange);
  
  //Enable checking
  for (int i = 1; i <= MaxClients; ++i) {
    if(IsClientInGame(i)) {
      g_CanCheckPlayTime = true;
    }
  }
  
  //Create config file
  AutoExecConfig(true, "playtime");
  
  //Set server ID
  g_ServerId = g_Cvar_PlayTimeServerId.IntValue;
  
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
  g_ServerId = StringToInt(newValue) ;
}


public void OnClientPutInServer(int client)
{
  if(IsFakeClient(client))
    return;
    
  //Reset play time for current session
  g_PlayTimeT[client] = 0;
  g_PlayTimeCt[client] = 0;
}

//Check player in the database to see if row exists for them
//If not insert it in now
public void OnClientAuthorized(int client, const char[] steamId)
{
  if(IsFakeClient(client))
    return;
  
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
    
    char query[1024];
    Format(query, sizeof(query), "INSERT IGNORE INTO pt_times(authid, name, ServerID) VALUES ('%s', '%s', %d)", steamId, clientName, g_ServerId);
    SQL_TQuery(db, DB_Callback_OnClientAuthorized, query, _);

    delete db;
  }
}

public void DB_Callback_OnClientAuthorized(Handle owner, Handle hndl, const char[] error, any data)
{
  if (hndl == null)
    LogError("Error updating play time at OnClientAuthorized: %s", error);
}

//Write changed to database on disconnect
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
    
    char query[1024];
    Format(query, sizeof(query), "UPDATE pt_times SET playtime_ct=playtime_ct+%d, playtime_t=playtime_t+%d, name='%s' WHERE authid = '%s' AND ServerID = %d", g_PlayTimeCt[client], g_PlayTimeT[client], clientName, steamId, g_ServerId);
    SQL_TQuery(db, DB_Callback_OnClientDisconnect, query, _);

    delete db;
  }
}

public void DB_Callback_OnClientDisconnect(Handle owner, Handle hndl, const char[] error, any data)
{
  if (hndl == null)
    LogError("Error updating play time at OnClientDisconnect: %s", error);
}

//Update local time played variables
public Action CheckTime(Handle timer)
{
  //For every player
  for (int i = 1; i <= MaxClients; ++i) {
    if (IsClientInGame(i)) {
      if (GetClientTeam(i) == CS_TEAM_T)
        ++g_PlayTimeT[i];
      else if (GetClientTeam(i) == CS_TEAM_CT)
        ++g_PlayTimeCt[i];
    }
  }
  
  return Plugin_Continue;
}

public Action Command_AdminCheckPlayTime(int client, int args)
{
  //Get arguments
  if (args != 1 && args != 2) {
    CPrintToChat(client, "%sUsage: sm_playtimecheck <player> or sm_playtimecheck <player> <CT|T>.", CHAT_TAG_PREFIX);
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
    CPrintToChat(client, "%sUsage: sm_playtimecheckall <player> or sm_playtimecheckall <player> <CT|T>.", CHAT_TAG_PREFIX);
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
    CPrintToChat(client, "%sUsage: sm_playtime or sm_playtime <CT|T>.", CHAT_TAG_PREFIX);
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
    CPrintToChat(client, "%sUsage: sm_playtimeall or sm_playtimeall <CT|T>.", CHAT_TAG_PREFIX);
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
      Format(query, sizeof(query), "SELECT name, playtime_ct + playtime_t as playtime FROM pt_times WHERE ServerID = %d ORDER BY playtime DESC LIMIT 100", g_ServerId);
      
      SQL_TQuery(db, DB_Callback_CheckPlayTimeTop, query, client);

      delete db;
    }
  }
  
  return Plugin_Handled;
}

/**
* Perform Playtime check
*/
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
    CPrintToChat(client, "%sTeam must be either {lightblue}CT{default} or {olive}T{default}.", CHAT_TAG_PREFIX);
    return;
  }
  
  //Look up players CT time and T time
  char steamId[32];
  if (!GetClientAuthId(target, AuthId_Steam2, steamId, sizeof(steamId))) {
    LogError("Could not get client auth ID at TriggerPlaytime");
    return;
  }
  
  //Query database
  char error[255];
  Handle db = SQL_Connect("playtime", true, error, sizeof(error));
   
  if (db == null) {
    PrintToServer("Could not connect: %s", error);
  } else {
    //Make datapack for query
    DataPack pack = new DataPack();
    pack.WriteCell(target); //target
    
    //Write team
    if (strlen(team) == 0)
      pack.WriteCell(0);
    else {
      if (StrEqual(team, "CT", false))
        pack.WriteCell(CS_TEAM_CT);
      else if (StrEqual(team, "T", false))
        pack.WriteCell(CS_TEAM_T);
    }
    
    //Write currentServerOnly
    pack.WriteCell(currentServerOnly);
    
    //Connection successful
    char query[1024];
    Format(query, sizeof(query), "SELECT SUM(playtime_ct), SUM(playtime_t) FROM pt_times WHERE authid = '%s'", steamId);
    
    //Check if we should restrict to current server
    if (currentServerOnly)
      Format(query, sizeof(query), "%s AND ServerID = %d", query, g_ServerId);
    
    SQL_TQuery(db, DB_Callback_CheckPlayTime, query, pack);

    delete db;
  }
}

//Re-enable playtime checking usage for particular client
public Action Timer_ReEnable_Usage(Handle timer, int client)
{
  g_CanCheckPlayTime[client] = true;
}

public void DB_Callback_CheckPlayTime(Handle owner, Handle hndl, const char[] error, DataPack pack)
{
  if (hndl == null) {
    LogError("Error selecting play time at Command_CheckPlayTime: %s", error);
  }
  else {
    pack.Reset();
    int client = pack.ReadCell();
    int team = pack.ReadCell();
    bool currentServerOnly = pack.ReadCell();
    
    int iRowCount = SQL_GetRowCount(hndl);
    if (iRowCount) {
      SQL_FetchRow(hndl);
      int db_PlayTimeCt = SQL_FetchInt(hndl, 0);
      int db_PlayTimeT = SQL_FetchInt(hndl, 1)
      
      char serverText[12];
      Format(serverText, sizeof(serverText), "this server");
      if (!currentServerOnly)
        Format(serverText, sizeof(serverText), "all servers");
      
      //Print out users playtime
      if (team == 0) { //both teams
        CPrintToChatAll("%s{lightgreen}%N's{default} total play time for {lightgreen}%s{default} is {lightgreen}%d{default} minutes.", CHAT_TAG_PREFIX, client, serverText, db_PlayTimeCt + db_PlayTimeT + g_PlayTimeCt[client] + g_PlayTimeT[client]);
      }
      else if (team == CS_TEAM_CT) {
        CPrintToChatAll("%s{lightgreen}%N's{default} play time on {lightblue}CT{default} for {lightgreen}%s{default} is {lightgreen}%d{default} minutes.", CHAT_TAG_PREFIX, client, serverText, db_PlayTimeCt + g_PlayTimeCt[client]);
      }
      else if (team == CS_TEAM_T) {
        CPrintToChatAll("%s{lightgreen}%N's{default} play time on {olive}T{default} for {lightgreen}%s{default} is {lightgreen}%d{default} minutes.", CHAT_TAG_PREFIX, client, serverText, db_PlayTimeT + g_PlayTimeT[client]);
      }
    }
  }
  
  delete pack;
}

public void DB_Callback_CheckPlayTimeTop(Handle owner, Handle hndl, const char[] error, int client)
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

void ShowTop100Menu(int client)
{
  if (IsFakeClient(client) || !IsClientInGame(client))
    return;
  
  //Create a menu
  Menu top100Menu = new Menu(Top100MenuHandler, MenuAction_Select|MenuAction_Cancel|MenuAction_End|MenuAction_DisplayItem);
  
  //need dummy items or else menu wont show correct pagination
  //Need 10 pages total
  for (int i = 0; i < MAX_MENU_OPTIONS * 10; ++i)
    top100Menu.AddItem("", "", ITEMDRAW_NOTEXT);
  
  top100Menu.Display(client, MENU_TIME_FOREVER);
}

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