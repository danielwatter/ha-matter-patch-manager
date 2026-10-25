"""Read-only update entity; installation intentionally disabled in phase 1."""

from homeassistant.components.update import UpdateEntity
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers.entity_platform import AddConfigEntryEntitiesCallback


async def async_setup_entry(
    hass: HomeAssistant,
    entry: ConfigEntry,
    async_add_entities: AddConfigEntryEntitiesCallback,
) -> None:
    """Register the placeholder entity until a safe status bridge exists."""
    async_add_entities([MatterPatchUpdate(entry.entry_id)])


class MatterPatchUpdate(UpdateEntity):
    """Never claim a patch is available without a verified check."""

    _attr_name = "Matter Core Patch"
    _attr_has_entity_name = False
    _attr_available = False
    _attr_supported_features = 0

    def __init__(self, entry_id: str) -> None:
        """Initialize the entity."""
        self._attr_unique_id = f"{entry_id}_matter_patch"
