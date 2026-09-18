-- +goose Up
-- +goose StatementBegin

-- Who was shown which arm of an A/B test, and when: the moment the arm's offer
-- first fired for them. A lord's arm is a keyed hash (game/experiments), so
-- this table is not where the arm is decided, only where the showing is
-- counted. No foreign key: a test's results do not change when an account is
-- deleted, as purchases do not.
CREATE TABLE app.experiment_exposures (
    experiment text        NOT NULL,
    player_id  uuid        NOT NULL,
    arm        text        NOT NULL,
    product_id text        NOT NULL,
    exposed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (experiment, player_id)
);

-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DROP TABLE IF EXISTS app.experiment_exposures;
-- +goose StatementEnd
