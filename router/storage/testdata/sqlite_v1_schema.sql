CREATE TABLE IF NOT EXISTS routing_decisions (
        trace_id TEXT PRIMARY KEY,
        created_at TEXT NOT NULL,
        run_mode TEXT NOT NULL CHECK (run_mode IN ('normal', 'benchmark', 'calibration')),
        request_profile_json TEXT NOT NULL,
        task_type TEXT NOT NULL,
        domain TEXT NOT NULL,
        complexity TEXT NOT NULL,
        quality_floor TEXT NOT NULL,
        latency_preference TEXT NOT NULL,
        privacy_level TEXT NOT NULL,
        risk_level TEXT NOT NULL,
        output_length TEXT NOT NULL,
        language TEXT NOT NULL,
        additional_capabilities_json TEXT NOT NULL,
        selected_candidate_identity TEXT,
        output_status TEXT NOT NULL,
        reason_code TEXT,
        effective_quality TEXT,
        quality_bottleneck TEXT,
        price TEXT,
        price_final INTEGER NOT NULL CHECK (price_final IN (0, 1)),
        latency_ms REAL,
        router_policy_version TEXT NOT NULL,
        profile_schema_version TEXT NOT NULL,
        model_profile_version TEXT NOT NULL,
        pricing_snapshot_date TEXT NOT NULL,
        quality_snapshot_date TEXT NOT NULL,
        calibration_set_version TEXT NOT NULL,
        prompt_hash TEXT NOT NULL,
        response_hash TEXT,
        prompt_content TEXT,
        response_content TEXT,
        candidate_count INTEGER NOT NULL CHECK (candidate_count >= 0)
    );

CREATE TABLE IF NOT EXISTS candidate_evaluations (
        trace_id TEXT NOT NULL,
        candidate_identity TEXT NOT NULL,
        launcher TEXT NOT NULL,
        configuration_id TEXT NOT NULL,
        provider TEXT NOT NULL,
        model TEXT NOT NULL,
        effort TEXT NOT NULL,
        eligible INTEGER NOT NULL CHECK (eligible IN (0, 1)),
        selected INTEGER NOT NULL CHECK (selected IN (0, 1)),
        rejection_stage TEXT,
        rejection_reason_codes_json TEXT NOT NULL,
        requirements_passed INTEGER CHECK (requirements_passed IN (0, 1)),
        requirements_json TEXT,
        quality_passed INTEGER CHECK (quality_passed IN (0, 1)),
        effective_quality TEXT,
        quality_bottleneck TEXT,
        quality_json TEXT,
        price_available INTEGER CHECK (price_available IN (0, 1)),
        price TEXT,
        price_final INTEGER CHECK (price_final IN (0, 1)),
        price_json TEXT,
        latency_available INTEGER NOT NULL CHECK (latency_available IN (0, 1)),
        latency_ms REAL,
        PRIMARY KEY (trace_id, candidate_identity),
        FOREIGN KEY (trace_id) REFERENCES routing_decisions(trace_id) ON DELETE RESTRICT
    );

CREATE INDEX IF NOT EXISTS idx_routing_decisions_created_at ON routing_decisions(created_at);
CREATE INDEX IF NOT EXISTS idx_routing_decisions_run_mode ON routing_decisions(run_mode);
CREATE INDEX IF NOT EXISTS idx_routing_decisions_output_status ON routing_decisions(output_status);
CREATE INDEX IF NOT EXISTS idx_routing_decisions_selected_candidate ON routing_decisions(selected_candidate_identity);
CREATE INDEX IF NOT EXISTS idx_candidate_evaluations_candidate_identity ON candidate_evaluations(candidate_identity);
