package com.jeromegsq.thortoolbox.autodim;

import android.graphics.drawable.Icon;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

import com.jeromegsq.thortoolbox.R;

/** Quick settings tile: turns dimming of the bottom screen on and off. */
public class DimTileService extends TileService {

    @Override
    public void onStartListening() {
        render(Settings.load(this));
    }

    @Override
    public void onClick() {
        Settings.Config cfg = Settings.load(this);
        cfg.enabled = !cfg.enabled;
        Settings.save(this, cfg);
        render(cfg);
    }

    private void render(Settings.Config cfg) {
        Tile tile = getQsTile();
        if (tile == null) {
            return;
        }
        tile.setState(cfg.enabled ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setLabel(getString(R.string.autodim_tile_label));
        tile.setSubtitle(cfg.enabled
                ? getString(R.string.autodim_tile_on, cfg.timeout)
                : getString(R.string.autodim_tile_off));
        tile.setIcon(Icon.createWithResource(this, R.drawable.ic_tile));
        tile.updateTile();
    }
}
