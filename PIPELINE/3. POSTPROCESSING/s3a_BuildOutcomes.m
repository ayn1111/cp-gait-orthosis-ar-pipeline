% s3a_BuildOutcomes.m   (v3 - divisor on session means; cadence in steps/min)
% =========================================================================
% STAGE 3, STEP 1 of 6.   Everything downstream reads this script's output.
%
% WHAT THIS PROCESSES
%   PROCESSED\SYNC\PUSHOFF_<P>.csv          primary outcomes   (s2d)
%   PROCESSED\SYNC\SPATIOTEMPORAL_<P>.csv   secondary outcomes (s2e)
%   PROCESSED\TRIALMAP_<P>.csv              condition per trial
%
% WHAT IT ACHIEVES
%   PROCESSED\RESULTS\OUTCOMES_<P>.csv      one row per trial per side, raw
%                                           AND normalised, with condition
%   PROCESSED\RESULTS\BASELINE_REF_<P>.csv  the divisors, one per leg per
%                                           variable, with the trials used
%
% ================= THE NORMALISATION RULE =================
% pushForce_mean is in RAW FSR COUNTS. Those are not comparable between legs
% (different sensors) or between sessions (the insole is refitted each time).
% The protocol's Figures 4 and 5 plot values from 0.5 to 1.9, which is
% impossible under division by a global maximum, so the reported outcome must
% be BASELINE-RELATIVE.
%
% THE RULE, taken from the study design and not from the data:
%   divisor = mean of the PRE-INTERVENTION SESSION MEANS of that variable,
%             computed SEPARATELY FOR EACH LEG.
%   Each session is first averaged over its own trials, then the baseline
%   sessions are averaged. v2 averaged the baseline TRIALS directly, which is
%   the same thing only when every baseline session has the same number of
%   valid trials. On CP03 left SOL and left GM lost one trial each in session
%   3, so v2's baseline phase mean came out 0.994 and 0.938 instead of 1.000.
%   Section 3.3 makes the session mean the unit of analysis, so the reference
%   is built from session means and the baseline phase mean is exactly 1.0
%   for every normalised variable. Ranks are unchanged, so NAP and Tau-U are
%   unchanged.
%
% Protocol Figure 3 fixes which sessions those are per group: Group 1 = 1-2,
% Group 2 = 1-3, Group 3 = 1-4, Group 4 = 1-5. This script reads it from the
% condition column of the trial map, so it is correct for any participant
% without anyone choosing anything. It was fixed by the design before any
% number was seen, which is what makes it defensible.
%
% It must be computed ONCE and applied to ALL sessions. Normalising each
% session by its own mean would make every session 1.0 by construction and
% erase the effect being measured.
% ==========================================================
%
% ============ WHAT NORMALISATION DOES NOT AFFECT ============
% NAP and Tau-U are rank-based. Dividing every value by the same constant
% cannot change any rank, so s3d's results are IDENTICAL whether it reads the
% raw or the normalised column. Normalisation matters for Figures 4 and 5,
% and for comparing the two legs. It does not manufacture or destroy effects.
% ============================================================
%
% ============ v3: CADENCE ============
% Cadence comes from s2e v6 in STEPS per minute (120 / median stride time,
% both shank gyros pooled). It is ONE value per trial, written on both legs'
% rows; this script checks the two rows agree and copies the value across if
% one row lacks it. PUSHOFF's cadence_spm (strides per minute from the FSR,
% a by-product of contact detection) is no longer carried, so only one
% cadence exists in OUTCOMES.
% ====================================
%
% NOTHING IS EXCLUDED. Trials with known sensor problems contribute to the
% baseline like any other. That is deliberate and it is your rule: the
% caveats live in ISSUES_<P>.txt and are handled in ONE pre-specified
% sensitivity re-run at the end, not by removing trials here.
%
% RUNTIME: seconds.
% =========================================================================

clear; clc;

% ===== USER SETTINGS =====
participant = 'CP03';
Root        = 'C:\INVESTIGACION CSIC\PAC03';
syncFolder  = fullfile(Root,'PROCESSED','SYNC');
TrialMapCsv = fullfile(Root,'PROCESSED',sprintf('TRIALMAP_%s.csv',participant));
outFolder   = fullfile(Root,'PROCESSED','RESULTS');

% Condition labels as they appear in the trial map.
BASELINE_LABEL = "AFO";        % pre-intervention
INTERV_LABEL   = "AFO_AR";     % intervention

% Variables normalised to baseline. These are the Figure 4 / Figure 5 ones.
% Everything else stays in physical units, where a number already means
% something on its own.
normVars = {'pushForce_mean','pushEMG_SOL','pushEMG_GM','pushEMG_TA', ...
            'pushForce_ratio','pushEMG_SOL_ratio','pushEMG_GM_ratio','pushEMG_TA_ratio'};
% v2: the four *_ratio variables (from s2d v4) are ALSO normalised to the
% baseline, purely so every Figure 4 / Figure 5 panel shares one axis
% convention (baseline = 1.0). They are already gain-invariant, and dividing
% by a constant cannot change any rank, so NAP and Tau-U are identical on
% the raw ratio and on the normalised one. Both columns are written.

TREND_WARN = 0.30;   % if a leg's baseline drifts by more than this fraction
                     % of its own mean, say so - a drifting baseline is what
                     % Tau-U corrects for and NAP does not.
% =========================

if ~exist(outFolder,'dir'), mkdir(outFolder); end

pushCsv = fullfile(syncFolder, sprintf('PUSHOFF_%s.csv', participant));
spatCsv = fullfile(syncFolder, sprintf('SPATIOTEMPORAL_%s.csv', participant));
for f = {pushCsv, spatCsv, TrialMapCsv}
    if ~isfile(f{1}), error('Not found:\n  %s', f{1}); end
end

P = readtable(pushCsv);
if ~ismember('pushForce_ratio', P.Properties.VariableNames)
    error(['%s has no pushForce_ratio column - it was written by s2d v3 or ' ...
           'earlier. Run s2d_PushOffMetrics.m (v4) first, then this script.'], pushCsv);
end
S = readtable(spatCsv, 'TextType','string');
if ~ismember('cadence_steps_min', S.Properties.VariableNames)
    error(['%s has no cadence_steps_min column - it was written by s2e v5 or ' ...
           'earlier (cadence in strides/min).\nRun s2c_Bundle.m (v2), then ' ...
           's2e_SpatioTemporal.m (v6), then this script.'], spatCsv);
end
M = loadMap(TrialMapCsv);

% ---- condition per trial, from the trial map ----
cond = strings(height(P),1);
for i = 1:height(P)
    r = find(M.trial == P.trial(i), 1);
    if ~isempty(r), cond(i) = M.condition(r); end
end
if any(cond == "")
    error('Some trials have no condition in the trial map. Fix TRIALMAP first.');
end

% ---- join the two outcome tables on trial + side ----
O = table();
O.trial     = P.trial;
O.session   = P.session;
O.condition = cond;
O.isRight   = P.isRight;
O.leg       = repmat("L", height(P), 1);
O.leg(P.isRight == 1) = "R";

carryP = {'trialStart_s','startFromHeelLift','nCycles','fsrUnloaded', ...
          'pushForce_ratio','pushEMG_SOL_ratio','pushEMG_GM_ratio','pushEMG_TA_ratio', ...
          'pushForce_mean', ...
          'pushForce_sd','pushEMG_SOL','pushEMG_GM','pushEMG_TA', ...
          'contact_s'};
for v = carryP
    if ismember(v{1}, P.Properties.VariableNames), O.(v{1}) = P.(v{1}); end
end

carryS = {'strideTime_s','cadence_steps_min', ...                       % trial-level
          'nStrides','strideTime_side_s','strideTime_iqr_s', ...           % this side
          'cadence_gaitup_steps_min','cadence_fsr_steps_min','cadence_spread_steps_min', ...
          'ankleROM_deg','ankleROM_sd','nROM'};
trialLevel = {'strideTime_s','cadence_steps_min'};   % one value per trial
for v = carryS, O.(v{1}) = nan(height(O),1); end
O.note = strings(height(O),1);
nMatched = 0;
for i = 1:height(O)
    r = find(S.trial == O.trial(i) & S.isRight == O.isRight(i), 1);
    if isempty(r), continue; end
    nMatched = nMatched + 1;
    for v = carryS
        if ismember(v{1}, S.Properties.VariableNames), O.(v{1})(i) = S.(v{1})(r); end
    end
    if ismember('note', S.Properties.VariableNames), O.note(i) = S.note(r); end
end
fprintf('Joined %d of %d rows between PUSHOFF and SPATIOTEMPORAL.\n', nMatched, height(O));
if nMatched < height(O)
    warning('%d row(s) had no spatiotemporal match - their secondary outcomes are NaN.', ...
            height(O)-nMatched);
end

% ---- trial-level variables: the two rows of a trial must hold ONE value ----
for v = trialLevel
    for k = unique(O.trial)'
        r = find(O.trial == k);
        x = O.(v{1})(r);
        fin = isfinite(x);
        if nnz(fin) > 1 && max(x(fin)) - min(x(fin)) > 1e-9*max(1, max(abs(x(fin))))
            error('Trial %d: %s differs between the two legs (%s). It must be one value per trial.', ...
                  k, v{1}, mat2str(x', 6));
        end
        if any(fin) && ~all(fin), O.(v{1})(r(~fin)) = x(find(fin,1)); end
    end
end

% ---- phases are defined per SESSION (v3) ----
% A session is an INTERVENTION session if it holds any AFO+AR walk, otherwise
% a BASELINE session. Inside a session only the walks of that phase's
% condition count (protocol 3.3: baseline sessions -> the orthosis-only
% blocks, intervention sessions -> the orthosis+AR blocks). So an AFO-only
% control block inside an AR session, if one is ever recorded, can never
% enter the baseline reference.
unk = setdiff(unique(O.condition), [BASELINE_LABEL INTERV_LABEL]);
if ~isempty(unk)
    error('Unknown condition label(s) in the trial map: %s', strjoin(unk, ', '));
end
intSessions  = unique(O.session(O.condition == INTERV_LABEL))';
baseSessions = setdiff(unique(O.session(O.condition == BASELINE_LABEL))', intSessions);
if ~isempty(baseSessions) && ~isempty(intSessions) && max(baseSessions) > min(intSessions)
    error(['Baseline session %d comes after the first intervention session (%d). ' ...
           'A multiple-baseline series must be A then B. Check TRIALMAP.'], ...
          max(baseSessions), min(intSessions));
end
isBase  = O.condition == BASELINE_LABEL & ismember(O.session, baseSessions);
inPhase = isBase | (O.condition == INTERV_LABEL & ismember(O.session, intSessions));
fprintf('\nBaseline phase = sessions %s (condition "%s")\n', ...
        mat2str(baseSessions), BASELINE_LABEL);
fprintf('Intervention   = sessions %s (condition "%s")\n\n', ...
        mat2str(intSessions), INTERV_LABEL);

% ---- baseline reference: one per leg per variable, computed ONCE ----

refRows = {};
for lg = ["L","R"]
    for v = normVars
        m  = isBase & O.leg == lg & isfinite(O.(v{1}));
        sm = [];                                   % one mean per baseline session
        for s = baseSessions
            ms = m & O.session == s;
            if any(ms), sm(end+1) = mean(O.(v{1})(ms)); end %#ok<AGROW>
        end
        ref = NaN;
        if ~isempty(sm), ref = mean(sm); end
        refRows(end+1,:) = {lg, string(v{1}), ref, numel(sm), nnz(m), ...
                            joinNums(O.trial(m), ',')}; %#ok<AGROW>
    end
end
R = cell2table(refRows,'VariableNames', ...
      {'leg','variable','baseline_ref','n_sessions','n_trials','trials_used'});
writetable(R, fullfile(outFolder, sprintf('BASELINE_REF_%s.csv', participant)));

fprintf('baseline_ref = mean of the baseline SESSION MEANS\n');
fprintf('%-4s %-18s %14s %6s %7s\n','leg','variable','baseline_ref','n_ses','n_trial');
fprintf('%s\n', repmat('-',1,54));
for i = 1:height(R)
    fprintf('%-4s %-18s %14.5g %6d %7d\n', R.leg(i), R.variable(i), R.baseline_ref(i), ...
            R.n_sessions(i), R.n_trials(i));
end

% ---- apply it ----
for lg = ["L","R"]
    for v = normVars
        ref = R.baseline_ref(R.leg == lg & R.variable == string(v{1}));
        nm  = [v{1} '_norm'];
        if ~ismember(nm, O.Properties.VariableNames), O.(nm) = nan(height(O),1); end
        m = O.leg == lg;
        if isfinite(ref) && ref > 0
            O.(nm)(m) = O.(v{1})(m) ./ ref;
        end
    end
end

writetable(O, fullfile(outFolder, sprintf('OUTCOMES_%s.csv', participant)));
fprintf('\nSaved -> %s\n', fullfile(outFolder, sprintf('OUTCOMES_%s.csv', participant)));

% ===== session-level summary, and the two things worth looking at =====
fprintf('\n=== SESSION MEANS, NORMALISED TO BASELINE ===\n');
sessAll = unique(O.session)';
for lg = ["L","R"]
    for v = normVars
        nm = [v{1} '_norm'];
        vals = nan(1, numel(sessAll));
        for j = 1:numel(sessAll)
            m = O.leg == lg & O.session == sessAll(j) & inPhase;
            vals(j) = mean(O.(nm)(m), 'omitnan');
        end
        if all(isnan(vals)), continue; end
        fprintf('\n%s %-16s ', lg, v{1});
        fprintf('%s\n', strjoin(arrayfun(@(s,x) sprintf('S%d=%.2f',s,x), ...
                sessAll, vals, 'uni', 0), '  '));

        % (a) does the baseline already drift?
        bIdx = ismember(sessAll, baseSessions);
        b = vals(bIdx); b = b(isfinite(b));
        if numel(b) >= 3
            drift = b(end) - b(1);
            if abs(drift) > TREND_WARN
                % v3: direction fixed. A RISING baseline makes NAP credit that rise
                % to the AR (overstates an increase); a FALLING one does the
                % reverse (understates an increase, overstates a decrease).
                fprintf(['   BASELINE TREND: %+.2f across phase A (%s). NAP ignores it and will\n' ...
                         '   %s an increase under AR. s3d reports Tau-U and the uncorrected\n' ...
                         '   contrast side by side.\n'], drift, ...
                        ternary(drift > 0, 'rising', 'falling'), ...
                        ternary(drift > 0, 'OVERSTATE', 'UNDERSTATE'));
            end
        end

        % (b) complete separation between phases?
        iIdx = ~bIdx;
        a = vals(bIdx); a = a(isfinite(a));
        c = vals(iIdx); c = c(isfinite(c));
        if ~isempty(a) && ~isempty(c)
            if max(c) < min(a)
                fprintf(['   COMPLETE SEPARATION DOWNWARD: every intervention session is below\n' ...
                         '   every baseline session. NAP will be 0.00. Before reporting this as\n' ...
                         '   deterioration, rule out a sensor change - the insole is refitted\n' ...
                         '   every session, so a gain shift produces exactly this pattern.\n']);
            elseif min(c) > max(a)
                fprintf('   COMPLETE SEPARATION UPWARD: NAP will be 1.00.\n');
            end
        end
    end
end

fprintf('\n=== NEXT ===\n');
fprintf('s3b (intra-session, Figure 4), s3c (inter-session, Figure 5), s3d (NAP and Tau-U).\n');
fprintf('All three read OUTCOMES_%s.csv. None of them recompute the baseline reference.\n', participant);

% ===== helpers =====
function out = ternary(c,a,b), if c, out = a; else, out = b; end, end

function s = joinNums(x, sep)
% Comma list of numbers; "" when there are none.
    if isempty(x), s = ""; else, s = strjoin(string(x(:)'), sep); end
end

function M = loadMap(csvPath)
    if ~isfile(csvPath), error('Trial map not found:\n  %s', csvPath); end
    opts = detectImportOptions(csvPath,'TextType','string');
    txt  = intersect({'date','condition','inGAIT_file','EMG_file','IMU_file', ...
                      'gaitup_day','gaitup_LF','gaitup_RF','notes'}, opts.VariableNames);
    if ~isempty(txt), opts = setvartype(opts, txt, 'string'); end
    num  = intersect({'trial','session'}, opts.VariableNames);
    if ~isempty(num), opts = setvartype(opts, num, 'double'); end
    M = readtable(csvPath, opts);
end
