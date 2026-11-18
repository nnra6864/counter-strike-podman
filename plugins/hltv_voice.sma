// Lets HLTV hear every player, so voice chat ends up in the recorded demos.
// Players still hear only who the game rules allow (alltalk, teams, dead/alive).
// Needs ReGameDLL and ReAPI.
#include <amxmodx>
#include <reapi>

public plugin_init()
{
	register_plugin("HLTV Voice", "1.0", "nnra")
	RegisterHookChain(RG_CSGameRules_CanPlayerHearPlayer, "@CanPlayerHearPlayer", false)
}

@CanPlayerHearPlayer(const listener, const sender)
{
	if (!is_user_hltv(listener))
		return HC_CONTINUE

	SetHookChainReturn(ATYPE_BOOL, true)
	return HC_SUPERCEDE
}
