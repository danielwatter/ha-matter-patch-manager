"""Configuration flow for Matter Core Patch Manager."""

import aiohttp
import voluptuous as vol

from homeassistant import config_entries
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from .const import CONF_BRIDGE_TOKEN, CONF_BRIDGE_URL, DEFAULT_BRIDGE_URL, DOMAIN


class MatterPatchManagerConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Configure one Matter Patch Manager instance."""

    VERSION = 1

    async def async_step_user(self, user_input=None):
        """Validate the status bridge before storing credentials."""
        await self.async_set_unique_id(DOMAIN)
        self._abort_if_unique_id_configured()
        errors = {}
        if user_input is not None:
            url = user_input[CONF_BRIDGE_URL].rstrip("/")
            token = user_input[CONF_BRIDGE_TOKEN]
            if url != DEFAULT_BRIDGE_URL:
                errors["base"] = "invalid_url"
            else:
                try:
                    session = async_get_clientsession(self.hass)
                    async with session.get(
                        url + "/status",
                        headers={"Authorization": f"Bearer {token}"},
                        timeout=aiohttp.ClientTimeout(total=95),
                    ) as response:
                        response.raise_for_status()
                        result = await response.json()
                        if result.get("status") not in (
                            "installed", "available", "incompatible", "error"
                        ):
                            raise ValueError("Invalid bridge response")
                except (aiohttp.ClientError, TimeoutError, ValueError):
                    errors["base"] = "cannot_connect"
                else:
                    return self.async_create_entry(
                        title="Matter Core Patch Manager",
                        data={CONF_BRIDGE_URL: url, CONF_BRIDGE_TOKEN: token},
                    )
        schema = vol.Schema(
            {
                vol.Required(CONF_BRIDGE_URL, default=DEFAULT_BRIDGE_URL): str,
                vol.Required(CONF_BRIDGE_TOKEN): str,
            }
        )
        return self.async_show_form(step_id="user", data_schema=schema, errors=errors)
