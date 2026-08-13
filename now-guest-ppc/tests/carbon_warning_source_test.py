"""Pin the startup warning and its durable local suppression seam."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
main = (ROOT / "now-guest-ppc/src/main.c").read_text()
warning = (ROOT / "now-guest-ppc/src/core/carbon_warning.c").read_text()
confirm = (ROOT / "now-guest-ppc/src/workshop/confirm.c").read_text()

assert main.find("conn_init();") < main.find(
    "now_carbon_warning_show_if_needed();"
), "warning must not pump the wire before conn_init"
assert 'Gestalt(gestaltCarbonVersion, &version)' in warning
assert '"Continue", "Don\'t Warn Again"' in warning
assert "!= kNowChoiceAlternative" in warning
assert "prefs.carbon_warning_suppressed = true;" in warning
assert "now_prefs_save(&prefs)" in warning
assert 'now_choose(heading, detail, action, "Cancel")' in confirm
assert "== kNowChoiceAction" in confirm
