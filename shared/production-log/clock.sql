CREATE TABLE IF NOT EXISTS clock_state (
 id INTEGER PRIMARY KEY CHECK(id=1),
 high_water_us INTEGER NOT NULL,
 last_production_us INTEGER
)
