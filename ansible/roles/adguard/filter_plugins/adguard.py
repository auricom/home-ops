"""Compare configuration independently of AdGuard's generated filter timestamps."""

from copy import deepcopy


def adguard_normalize(config):
    result = deepcopy(config)
    for key in ("filters", "whitelist_filters"):
        for entry in result.get(key, []):
            entry.pop("last_updated", None)
    return result


class FilterModule:
    def filters(self):
        return {"adguard_normalize": adguard_normalize}
