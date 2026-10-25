"""Configuration flow for Matter Core Patch Manager."""

from homeassistant import config_entries

from .const import DOMAIN


class MatterPatchManagerConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Create a single Matter Patch Manager instance."""

    VERSION = 1

    async def async_step_user(self, user_input=None):
        """Create the configuration entry."""
        await self.async_set_unique_id(DOMAIN)
        self._abort_if_unique_id_configured()
        return self.async_create_entry(title="Matter Core Patch Manager", data={})
