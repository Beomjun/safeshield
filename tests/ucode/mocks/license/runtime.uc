'use strict';

let state = { refresh_count: 0, accepted: true, reason: '' };

return {
    state: state,
    start_refresh_async: function() {
        state.refresh_count++;
        return { accepted: state.accepted, reason: state.reason };
    }
};
