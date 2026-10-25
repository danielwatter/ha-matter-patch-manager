"""Read-only Matter Core Patch update entity; installation is disabled."""

import logging

import aiohttp

from homeassistant.components.update import UpdateEntity, UpdateEntityFeature
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback

from .const import CONF_BRIDGE_TOKEN, CONF_BRIDGE_URL

_LOGGER = logging.getLogger(__name__)
SCAN_INTERVAL = __import__("datetime").timedelta(minutes=30)


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    """Register the read-only update entity."""
    async_add_entities([MatterPatchUpdate(hass, entry)], update_before_add=True)


class MatterPatchUpdate(UpdateEntity):
    """Show an update only when the bridge verifies patch applicability."""

    _attr_name = "Matter Core Patch"
    _attr_has_entity_name = False
    _attr_supported_features = UpdateEntityFeature(0)
    _attr_installed_version = "installed"
    _attr_latest_version = "installed"

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        """Initialize the entity."""
        self._hass = hass
        self._entry = entry
        self._attr_unique_id = f"{entry.entry_id}_matter_patch"
        self._attr_available = False

    async def async_update(self) -> None:
        """Read patch status without modifying Core or running an installer."""
        try:
            session = async_get_clientsession(self._hass)
            async with session.get(
                self._entry.data[CONF_BRIDGE_URL] + "/status",
                headers={
                    "Authorization": f"Bearer {self._entry.data[CONF_BRIDGE_TOKEN]}"
                },
                timeout=aiohttp.ClientTimeout(total=95),
            ) as response:
                response.raise_for_status()
                result = await response.json()
                status = result.get("status")
                if status not in ("installed", "available"):
                    raise ValueError(f"Patch status not actionable: {status}")
        except (aiohttp.ClientError, TimeoutError, ValueError, KeyError) as exc:
            _LOGGER.warning("Matter patch status unavailable: %s", type(exc).__name__)
            self._attr_available = False
            return

        self._attr_installed_version = "unpatched" if status == "available" else "patched"
        self._attr_latest_version = "patched"
        self._attr_available = True
