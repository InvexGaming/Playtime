#if defined _playtime_included
	#endinput
#endif
#define _playtime_included

//Shared plugin information
public SharedPlugin:_pl_playtime = 
{
	name = "playtime",
	file = "playtime.smx",
#if defined REQUIRE_PLUGIN
	required = 1
#else
	required = 0
#endif
};

#if !defined REQUIRE_PLUGIN
public _pl_playtime_SetNTVOptional()
{
	MarkNativeAsOptional("GetClientPlayTime");
	MarkNativeAsOptional("GetClientPlayTimeAll");
}
#endif

/**
 *
 * Returns a client playtime on the current server
 *
 * @param client 	The client index
 * @param team 	The team index to get playtime for or 0 for all 
 *
 * @error 			Client is not valid, ingame, or client is a bot.
 *
 * @return 			The clients playtime in minutes
 *
 */

native int GetClientPlayTime(int client, int team = 0);

/**
 *
 * Returns a client playtime on all servers
 *
 * @param client 	The client index
 * @param team 	The team index to get playtime for or 0 for all 
 *
 * @error 			Client is not valid, ingame, or client is a bot.
 *
 * @return 			The clients playtime in minutes
 *
 */
native int GetClientPlayTimeAll(int client, int team = 0);
