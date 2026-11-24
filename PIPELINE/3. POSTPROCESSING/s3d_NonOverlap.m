% s3d_NonOverlap.m   (v1.2 - figure fixes only: legend labels, statistics box
%                      no longer covers data, hollow marker = inside the
%                      baseline band exactly. Every number identical to v1.)
% =========================================================================
% STAGE 3, STEP 4 of 6.   Protocol section 3.3 - NAP and Tau-U.
%
% WHAT THIS PROCESSES
%   PROCESSED\RESULTS\OUTCOMES_<P>.csv      (from s3a)
%
% WHAT IT ACHIEVES
%   PROCESSED\RESULTS\NONOVERLAP_<P>.csv    one row per variable per leg:
%       NAP, S_A, S_B, the two Equation 1 terms, Tau-U, bands, notes
%   PROCESSED\RESULTS\PAIRS_<P>.csv         every pair that was compared,
%       with its score - the protocol's pair comparison table (Figure 9)
%   PROCESSED\RESULTS\FIG6_9\<variable>.png per leg: the session series with
%       overlapping points marked (Figs. 6 and 8), the A x B pair table
%       (Fig. 9) and the baseline-trend pair table (Fig. 7)
%
% DATA POINTS (protocol 3.3): "each point used for the calculation
% corresponded to the mean value of a variable obtained during a session. For
% baseline sessions, the mean of the blocks performed only with the orthosis
% was used, whereas for intervention sessions, the mean of the blocks performed
% under the orthosis + augmented reality condition was used".
%   A session is an intervention (B) session if it holds any AFO+AR walk,
%   otherwise a baseline (A) session; its data point is the mean of the walks
%   of that phase's condition only. Points are taken in session order.
%
% THE CALCULATION, exactly as the protocol writes it
%   NAP   = [ #(b > a) + 0.5 #(b = a) ] / (nA nB)       over all A x B pairs
%   S_A   = sum over ALL baseline pairs i < j of sign(a_j - a_i)
%   S_B   = sum over all A x B pairs of sign(b - a)
%   Tau-U = Tau(non-overlap) - Tau(baseline) = (S_B - S_A) / (nA nB)   (Eq. 1)
% so the two Equation 1 terms are written as
%   tau_nonoverlap_eq1 = S_B / (nA nB)   = the uncorrected A-vs-B contrast
%                                          (= 2 NAP - 1; Figure 9's "raw A-vs-B Tau")
%   tau_baseline_eq1   = S_A / (nA nB)
% and tau_U = tau_nonoverlap_eq1 - tau_baseline_eq1 exactly.
%
% TWO WORDING POINTS IN THE PROTOCOL, and what is done
%   - It says "all CONSECUTIVE pairs ... for each pair (x_i, x_j) where j > i".
%     Parker et al. (2011) Tau trend uses ALL pairs i < j (Kendall's S), and
%     "where j > i" says the same. All pairs are used: with 4 baseline points,
%     6 pairs (consecutive-only would be 3 and a different S_A).
%   - It says the denominator standardises Tau-U to [-1, +1]. Under Eq. 1 it
%     does not: |S_B - S_A| can reach nA nB + nA(nA-1)/2 (30/24 = 1.25 here).
%     Values beyond +/-1 are flagged, never clipped.
%
% DIRECTION. The equations score b > a as +1, so positive = higher under AR.
% Where the protocol's aim fixes which way is better - propulsion: push-off
% force and plantar-flexor (SOL, GM) EMG, higher is better - higher_is_better
% is 1 and the protocol's words apply ("deterioration" when NAP < 0.5).
% For TA at push-off, cadence and ankle ROM the protocol does not say which way
% is better; higher_is_better is 0 and the result reads "higher/lower under AR".
%
% BANDS (protocol 3.3)
%   NAP          weak < 0.66 <= medium < 0.93 <= strong; and, where
%                higher_is_better = 1, NAP < 0.5 is "deterioration" (the
%                protocol's [0-0.49] band) rather than "weak"
%   |Tau-U|      small < 0.20 <= moderate < 0.60 <= large < 0.80 <= very large
% When higher_is_better = 0 the NAP band is taken on max(NAP, 1 - NAP), i.e. the
% NAP of whichever direction the change went, and the direction is stated.
%
% ============ READ THIS BEFORE QUOTING A TAU-U ============
% Equation 1 subtracts S_A whatever its sign. The protocol's reason for it is to
% stop a baseline that was ALREADY improving from being credited to the AR.
% When the baseline trended the OTHER way, subtracting a negative S_A makes
% Tau-U LARGER than the uncorrected contrast. Both numbers are written, and the
% correction_note column states which case applies (REDUCES / ENLARGES /
% REVERSES the sign). With 4 baseline sessions, S_A rests on only 6 pairs.
% ==========================================================
%
% TIES. Two session means count as tied when they differ by less than TIE_TOL
% of their size, so floating-point noise can never decide a pair.
%
% SELF-TESTS, run before any data are read
%   1. The protocol's own worked example (Figures 6-9): A = 5.0 6.0,
%      B = 4.5 5.5 6.5 7.0 7.5 8.0 7.0 8.5. Must give NAP = 13/16, S_A = +1,
%      S_B = +10, Tau-U = 9/16 = 0.5625.
%      NOTE: the protocol's Figures 8-9 print "12 concordant - 4 discordant
%      = +8" and Tau-U = 0.44 for this example. Their own pair table (row sums
%      +6 and +4) and Figure 6 (13 non-overlapping pairs) give 13 - 3 = +10, so
%      the printed +8 / 0.44 is an arithmetic slip in the example. The method
%      is the same; the example's numbers should be corrected in the protocol.
%   2. Rank invariance: every normalised variable is also run on its RAW
%      column. NAP, S_A and S_B must be identical (dividing by a constant
%      cannot change an order). If not, the script stops.
%
% NOTHING IS EXCLUDED. A session with no valid trial has no data point; nA, nB
% and missing_sessions record exactly what entered. The sensitivity re-run that
% uses ISSUES_<P>.txt is a separate, later script.
%
% RUNTIME: under a minute.
% =========================================================================

clear; clc; close all;

% ===== USER SETTINGS =====
participant = 'CP03';
Root        = 'C:\INVESTIGACION CSIC\PAC03';
resFolder   = fullfile(Root,'PROCESSED','RESULTS');
outcomesCsv = fullfile(resFolder, sprintf('OUTCOMES_%s.csv', participant));
figFolder   = fullfile(resFolder, 'FIG6_9');

BASELINE_LABEL = "AFO";
INTERV_LABEL   = "AFO_AR";

% {column, label, raw column for the rank check ('' = none), higher_is_better, level}
VARS = {
  'pushForce_mean_norm',    'Push-off force (protocol measure)',             'pushForce_mean',    1, 'leg'
  'pushForce_ratio_norm',   'Push-off force share of contact (ratio)',       'pushForce_ratio',   1, 'leg'
  'pushEMG_SOL_norm',       'Soleus EMG at push-off (protocol)',             'pushEMG_SOL',       1, 'leg'
  'pushEMG_SOL_ratio_norm', 'Soleus EMG share at push-off (ratio)',          'pushEMG_SOL_ratio', 1, 'leg'
  'pushEMG_GM_norm',        'Gastrocnemius med. EMG at push-off (protocol)', 'pushEMG_GM',        1, 'leg'
  'pushEMG_GM_ratio_norm',  'Gastrocnemius med. EMG share (ratio)',          'pushEMG_GM_ratio',  1, 'leg'
  'pushEMG_TA_norm',        'Tibialis ant. EMG at push-off (protocol)',      'pushEMG_TA',        0, 'leg'
  'pushEMG_TA_ratio_norm',  'Tibialis ant. EMG share (ratio)',               'pushEMG_TA_ratio',  0, 'leg'
  'cadence_steps_min',      'Cadence (steps/min)',                           '',                  0, 'trial'
  'ankleROM_deg',           'Ankle range of motion (deg)',                   '',                  0, 'leg'
  };

TIE_TOL  = 1e-9;                 % relative tolerance for a tie
COL_BASE = [0.20 0.45 0.75];
COL_INT  = [0.90 0.50 0.10];
CMAP3    = [0.94 0.70 0.70; 0.88 0.88 0.88; 0.70 0.88 0.72];   % -1, 0, +1
% =========================

% ---------- self-test 1: the protocol's worked example ----------
R0 = nonOverlap([5.0 6.0], [4.5 5.5 6.5 7.0 7.5 8.0 7.0 8.5], TIE_TOL);
ok0 = abs(R0.NAP - 13/16) < 1e-12 && R0.S_A == 1 && R0.S_B == 10 && ...
      abs(R0.tauU - 9/16) < 1e-12 && abs(R0.tauNO - 10/16) < 1e-12 && ...
      abs(R0.tauNO - R0.tauBL - R0.tauU) < 1e-12;
if ~ok0
    error('Self-test 1 FAILED on the protocol example: NAP %.4f, S_A %d, S_B %d, Tau-U %.4f', ...
          R0.NAP, R0.S_A, R0.S_B, R0.tauU);
end
fprintf(['Self-test 1 (protocol example, Figs 6-9): NAP = 13/16 = %.4f, S_A = %+d, ' ...
         'S_B = %+d, Tau-U = 9/16 = %.4f.  OK\n'], R0.NAP, R0.S_A, R0.S_B, R0.tauU);
fprintf(['   (The protocol''s Figs 8-9 print S_B = +8 and Tau-U = 0.44 for this example;\n' ...
         '    their own pair table sums to +10. See the header of this script.)\n\n']);

if ~isfile(outcomesCsv)
    error('Not found:\n  %s\nRun s3a_BuildOutcomes.m first.', outcomesCsv);
end
if ~exist(figFolder,'dir'), mkdir(figFolder); end
old = dir(fullfile(figFolder, '*.png'));       % no stale figure from an older run
for q = 1:numel(old), delete(fullfile(old(q).folder, old(q).name)); end

O = readtable(outcomesCsv, 'TextType','string');
if ~ismember('cadence_steps_min', O.Properties.VariableNames)
    error(['OUTCOMES has no cadence_steps_min - it was built by s3a v2 or earlier. ' ...
           'Run s2c v2, s2e v6 and s3a v3 first.']);
end
unk = setdiff(unique(O.condition), [BASELINE_LABEL INTERV_LABEL]);
if ~isempty(unk)
    error('Unknown condition label(s) in OUTCOMES: %s', strjoin(unk, ', '));
end
intSess   = unique(O.session(O.condition == INTERV_LABEL))';
baseSess  = setdiff(unique(O.session(O.condition == BASELINE_LABEL))', intSess);
if isempty(baseSess) || isempty(intSess)
    error('Need at least one baseline and one intervention session.');
end
if max(baseSess) > min(intSess)
    error('Baseline session %d comes after intervention session %d. Check TRIALMAP.', ...
          max(baseSess), min(intSess));
end
phaseLine = max(baseSess) + 0.5;
fprintf('Phase A (%s) = sessions %s | phase B (%s) = sessions %s\n\n', ...
        BASELINE_LABEL, mat2str(baseSess), INTERV_LABEL, mat2str(intSess));

resRows = {}; pairRows = {}; nRank = 0;
for v = 1:size(VARS,1)
    col = VARS{v,1}; lab = VARS{v,2}; rawCol = VARS{v,3}; hib = VARS{v,4};
    level = string(VARS{v,5});
    if ~ismember(col, O.Properties.VariableNames)
        fprintf('%-24s not in OUTCOMES - skipped\n', col); continue;
    end
    isNorm = endsWith(string(col), "_norm");
    if level == "trial", checkTrialLevel(O, col); legs = "B"; else, legs = ["L","R"]; end
    legsWithData = strings(0);
    for lg = legs
        if any(isfinite(O.(col)(legMask(O, lg)))), legsWithData(end+1) = lg; end %#ok<AGROW>
    end
    if isempty(legsWithData)
        fprintf('%-24s no data on any leg - skipped\n', col); continue;
    end

    fig = figure('Color','w','Visible','off', ...
                 'Position',[60 60 1800 470*numel(legsWithData)]);
    tl  = tiledlayout(numel(legsWithData), 5, 'TileSpacing','compact', 'Padding','compact');
    title(tl, sprintf('%s - %s - NAP and Tau-U on session means', lab, participant), ...
          'FontWeight','bold');

    for lg = legsWithData
        m = legMask(O, lg);
        [xA, yA] = phaseMeans(O, col, m, baseSess, BASELINE_LABEL);
        [xB, yB] = phaseMeans(O, col, m, intSess,  INTERV_LABEL);
        missSess = setdiff([baseSess intSess], [xA xB]);
        missTxt  = joinNums(missSess, ',');

        if numel(yA) < 2 || numel(yB) < 1
            resRows(end+1,:) = {string(col), string(lab), lg, hib, numel(yA), numel(yB), ...
                joinNums(xA, ','), joinNums(xB, ','), "", "", missTxt, ...
                NaN, "", NaN, NaN, NaN, NaN, NaN, "", "not computed", ...
                "needs at least 2 baseline and 1 intervention session", "n/a"}; %#ok<AGROW>
            nexttile([1 5]); axis off;
            text(0.5, 0.5, sprintf('%s: fewer than 2 baseline or 1 intervention session with data', ...
                 legTitle(lg)), 'Units','normalized', 'HorizontalAlignment','center');
            continue;
        end

        R = nonOverlap(yA, yB, TIE_TOL);

        % ---- self-test 2: the same answer on the raw (un-normalised) column ----
        rawNote = "n/a";
        if ~isempty(rawCol) && ismember(rawCol, O.Properties.VariableNames)
            [rxA, rA] = phaseMeans(O, rawCol, m, baseSess, BASELINE_LABEL);
            [rxB, rB] = phaseMeans(O, rawCol, m, intSess,  INTERV_LABEL);
            R2 = nonOverlap(rA, rB, TIE_TOL);
            if ~isequal(rxA, xA) || ~isequal(rxB, xB) || R2.S_A ~= R.S_A || ...
               R2.S_B ~= R.S_B || abs(R2.NAP - R.NAP) > 1e-12
                error(['Rank check FAILED for %s, leg %s: the raw and the normalised ' ...
                       'column give different results. Stop and investigate OUTCOMES.'], col, lg);
            end
            rawNote = "identical on " + string(rawCol);
            nRank = nRank + 1;
        end

        [napBand, tauBand, interp, corrNote] = describe(R, hib);
        resRows(end+1,:) = {string(col), string(lab), lg, hib, R.nA, R.nB, ...
            joinNums(xA, ','), joinNums(xB, ','), ...
            strjoin(compose('%.4g', yA), '; '), strjoin(compose('%.4g', yB), '; '), missTxt, ...
            R.NAP, napBand, R.S_A, R.S_B, R.tauNO, R.tauBL, R.tauU, tauBand, ...
            interp, corrNote, rawNote}; %#ok<AGROW>

        % ---- every pair, for the pair comparison table ----
        for i = 1:R.nA
            for j = i+1:R.nA
                sc = cmp(yA(j), yA(i), TIE_TOL);
                pairRows(end+1,:) = {string(col), lg, "A_trend", xA(i), xA(j), ...
                                     yA(i), yA(j), sc, NaN}; %#ok<AGROW>
            end
        end
        for i = 1:R.nA
            for j = 1:R.nB
                sc = cmp(yB(j), yA(i), TIE_TOL);
                pairRows(end+1,:) = {string(col), lg, "A_vs_B", xA(i), xB(j), ...
                                     yA(i), yB(j), sc, (sc+1)/2}; %#ok<AGROW>
            end
        end

        % ---------- tile 1: the series (protocol Figs 6 and 8) ----------
        nexttile([1 2]); hold on; grid on; box on;
        xl = [min([xA xB])-0.6, max([xA xB])+0.6];
        hP = patch([xl(1) xl(2) xl(2) xl(1)], [min(yA) min(yA) max(yA) max(yA)], ...
                   COL_BASE, 'FaceAlpha', 0.12, 'EdgeColor', 'none');
        hA = plot(xA, yA, '-o', 'Color', COL_BASE, 'MarkerFaceColor', COL_BASE, ...
                  'LineWidth', 1.3, 'MarkerSize', 7);
        plot(xB, yB, '-', 'Color', COL_INT, 'LineWidth', 1.3);
        % Hollow marker = phase-B session mean INSIDE the baseline range (the
        % shaded band); filled = outside it. v1.2: classified by the band only,
        % so the marker always means what its legend says.
        ov = yB >= min(yA) & yB <= max(yA);
        % v1.1: a marker type with no points gets no legend entry. (v1 passed an
        % empty handle to legend, which shifted the labels by one place.)
        hList = [hP hA]; lList = {'baseline range', 'phase A (AFO)'};
        if any(~ov)
            hList(end+1) = plot(xB(~ov), yB(~ov), 'o', 'Color', COL_INT, ...
                                'MarkerFaceColor', COL_INT, 'MarkerSize', 7); %#ok<AGROW>
            lList{end+1} = 'phase B outside baseline range';
        end
        if any(ov)
            hList(end+1) = plot(xB(ov), yB(ov), 'o', 'Color', COL_INT, ...
                                'MarkerFaceColor', 'w', 'MarkerSize', 7, 'LineWidth', 1.5); %#ok<AGROW>
            lList{end+1} = 'phase B within baseline range';
        end
        xline(phaseLine, '--', 'Color', [0.4 0.4 0.4]);
        if isNorm, yline(1, ':', 'Color', [0.4 0.4 0.4]); end
        xlim(xl); xticks(unique([xA xB]));
        % v1.1: keep the top band of the panel free for the statistics box, so
        % the box can never hide a data point (v1 covered sessions 1-2).
        yAll = [yA yB]; yLo = min(yAll); yHi = max(yAll); yRg = yHi - yLo;
        if yRg <= 0, yRg = 0.1*max(abs(yHi), 1); end
        ylim([yLo - 0.08*yRg, yHi + 0.65*yRg]);
        xlabel('Session');
        ylabel(ternary(isNorm, 'normalised to baseline', lab));
        title(sprintf('%s - one point per session', legTitle(lg)));
        txt = {sprintf('NAP = %g/%d = %.2f  (%s)', R.nGT + 0.5*R.nEQ, R.nA*R.nB, R.NAP, napBand), ...
               sprintf('S_A = %s     S_B = %s', sgnStr(R.S_A), sgnStr(R.S_B)), ...
               sprintf('Tau-U = (S_B - S_A)/(n_A n_B) = %.2f  (%s)', R.tauU, tauBand), ...
               sprintf('Tau(non-overlap) = S_B/(n_A n_B) = %.2f  (uncorrected)', R.tauNO)};
        text(0.02, 0.97, txt, 'Units','normalized', 'VerticalAlignment','top', ...
             'FontSize', 8.5, 'BackgroundColor', 'w', 'EdgeColor', [0.7 0.7 0.7]);
        legend(hList, lList, 'Location','southoutside', 'Orientation','horizontal', ...
               'FontSize', 8);

        % ---------- tile 2: A x B pair table (protocol Fig 9) ----------
        nexttile([1 2]);
        Mx = zeros(R.nA, R.nB);
        for i = 1:R.nA
            for j = 1:R.nB, Mx(i,j) = cmp(yB(j), yA(i), TIE_TOL); end
        end
        imagesc(Mx, [-1 1]); colormap(gca, CMAP3); hold on;
        for i = 1:R.nA
            for j = 1:R.nB
                text(j, i, sgnStr(Mx(i,j)), 'HorizontalAlignment','center', 'FontSize', 9);
            end
            text(R.nB + 0.8, i, sgnStr(sum(Mx(i,:))), 'HorizontalAlignment','center', ...
                 'FontWeight','bold', 'FontSize', 9);
        end
        xlim([0.5, R.nB + 1.3]); ylim([0.5, R.nA + 0.5]);
        set(gca, 'XTick', 1:R.nB, 'XTickLabel', compose('S%d (%.4g)', xB(:), yB(:)), ...
                 'YTick', 1:R.nA, 'YTickLabel', compose('S%d (%.4g)', xA(:), yA(:)), ...
                 'XTickLabelRotation', 40, 'FontSize', 8, 'TickLength', [0 0]);
        xlabel('phase B session (mean)'); ylabel('phase A session (mean)');
        title(sprintf('A x B pairs: S_B = %s  (%d higher, %d lower, %d tied; right = row sum)', ...
              sgnStr(R.S_B), R.nGT, R.nLT, R.nEQ), 'FontSize', 9);

        % ---------- tile 3: baseline trend pairs (protocol Fig 7) ----------
        nexttile;
        Ma = nan(R.nA);
        for i = 1:R.nA
            for j = i+1:R.nA, Ma(i,j) = cmp(yA(j), yA(i), TIE_TOL); end
        end
        h = imagesc(Ma, [-1 1]); colormap(gca, CMAP3); hold on;
        set(h, 'AlphaData', double(isfinite(Ma)));
        for i = 1:R.nA
            for j = i+1:R.nA
                text(j, i, sgnStr(Ma(i,j)), 'HorizontalAlignment','center', 'FontSize', 9);
            end
        end
        set(gca, 'XTick', 1:R.nA, 'XTickLabel', compose('S%d', xA(:)), ...
                 'YTick', 1:R.nA, 'YTickLabel', compose('S%d', xA(:)), ...
                 'FontSize', 8, 'TickLength', [0 0]);
        xlabel('later session'); ylabel('earlier session');
        title(sprintf('Baseline trend: S_A = %s', sgnStr(R.S_A)), 'FontSize', 9);
    end

    exportgraphics(fig, fullfile(figFolder, [col '.png']), 'Resolution', 150);
    close(fig);
    fprintf('%-24s -> FIG6_9\\%s.png\n', col, col);
end

% ===== tables =====
if isempty(resRows), error('No variable could be analysed - check OUTCOMES.'); end
Rt = cell2table(resRows, 'VariableNames', {'variable','label','leg','higher_is_better', ...
      'nA','nB','sessions_A','sessions_B','values_A','values_B','missing_sessions', ...
      'NAP','NAP_band','S_A','S_B','tau_nonoverlap_eq1','tau_baseline_eq1','tau_U', ...
      'tau_U_band','interpretation','correction_note','raw_check'});
Pt = cell2table(pairRows, 'VariableNames', {'variable','leg','component', ...
      'session_i','session_j','value_i','value_j','score','nap_credit'});
writetable(Rt, fullfile(resFolder, sprintf('NONOVERLAP_%s.csv', participant)));
writetable(Pt, fullfile(resFolder, sprintf('PAIRS_%s.csv', participant)));
fprintf('\nSaved NONOVERLAP_%s.csv and PAIRS_%s.csv to %s\n', participant, participant, resFolder);
fprintf('Self-test 2 (rank invariance): raw and normalised identical on all %d rows checked.\n', nRank);

% ===== console summary =====
fprintf('\n=== NAP AND TAU-U (protocol 3.3, one point per session) ===\n');
fprintf('%-24s %-2s %2s %2s %6s %-13s %4s %4s %7s %7s %-11s %s\n', 'variable','lg','nA', ...
        'nB','NAP','NAP band','S_A','S_B','TauNO','Tau-U','Tau-U band','direction');
fprintf('%s\n', repmat('-',1,118));
for i = 1:height(Rt)
    fprintf('%-24s %-2s %2d %2d %6.3f %-13s %4d %4d %7.3f %7.3f %-11s %s\n', Rt.variable(i), ...
            Rt.leg(i), Rt.nA(i), Rt.nB(i), Rt.NAP(i), Rt.NAP_band(i), Rt.S_A(i), Rt.S_B(i), ...
            Rt.tau_nonoverlap_eq1(i), Rt.tau_U(i), Rt.tau_U_band(i), Rt.interpretation(i));
end
fprintf('TauNO = Tau(non-overlap) = S_B/(nA nB), the uncorrected contrast. Tau-U = TauNO - S_A/(nA nB).\n');
enl = Rt(contains(Rt.correction_note, "ENLARGES") | contains(Rt.correction_note, "REVERSES"), :);
if ~isempty(enl)
    fprintf(['\nOn %d row(s) Equation 1 ENLARGES the effect or REVERSES its sign, because\n' ...
             'of the baseline trend. Quote the uncorrected Tau A vs B beside Tau-U:\n'], height(enl));
    for i = 1:height(enl)
        fprintf('   %-24s %s  Tau-U %+.3f  vs  uncorrected %+.3f  (%s)\n', enl.variable(i), ...
                enl.leg(i), enl.tau_U(i), enl.tau_nonoverlap_eq1(i), ...
                ternary(contains(enl.correction_note(i), "REVERSES"), "reversed", "enlarged"));
    end
end
fprintf('\nLeg "B" = both legs (trial-level variable). Every pair is in PAIRS_%s.csv.\n', participant);

% ===== helpers =====
function R = nonOverlap(yA, yB, tol)
% NAP and Tau-U exactly as protocol section 3.3 / Equation 1.
    nA = numel(yA); nB = numel(yB);
    S_A = 0;
    for i = 1:nA
        for j = i+1:nA
            S_A = S_A + cmp(yA(j), yA(i), tol);
        end
    end
    S_B = 0; nGT = 0; nEQ = 0; nLT = 0;
    for i = 1:nA
        for j = 1:nB
            c = cmp(yB(j), yA(i), tol);
            S_B = S_B + c;
            if c > 0, nGT = nGT + 1; elseif c < 0, nLT = nLT + 1; else, nEQ = nEQ + 1; end
        end
    end
    R.nA = nA; R.nB = nB; R.S_A = S_A; R.S_B = S_B;
    R.nGT = nGT; R.nEQ = nEQ; R.nLT = nLT;
    R.NAP   = (nGT + 0.5*nEQ)/(nA*nB);
    R.tauNO = S_B/(nA*nB);                 % Tau(non-overlap), Equation 1
    R.tauBL = S_A/(nA*nB);                 % Tau(baseline),    Equation 1
    R.tauU  = (S_B - S_A)/(nA*nB);         % Tau-U = tauNO - tauBL
end

function s = cmp(b, a, tol)
% +1 if b > a, -1 if b < a, 0 if they are equal to within tol of their size.
    if abs(b - a) <= tol*max(abs(a), abs(b)), s = 0; else, s = sign(b - a); end
end

function [x, y] = phaseMeans(O, col, m, sess, label)
% One data point per session (protocol 3.3): the mean of its valid walks of
% the phase's condition.
    x = []; y = [];
    for s = sess
        v = O.(col)(m & O.session == s & O.condition == label);
        v = v(isfinite(v));
        if ~isempty(v), x(end+1) = s; y(end+1) = mean(v); end %#ok<AGROW>
    end
end

function [napBand, tauBand, interp, corrNote] = describe(R, hib)
    napEff = R.NAP;
    if hib == 0, napEff = max(R.NAP, 1 - R.NAP); end
    if napEff >= 0.93, napBand = "strong"; elseif napEff >= 0.66, napBand = "medium";
    else, napBand = "weak"; end
    if hib == 1 && R.NAP < 0.5, napBand = "deterioration"; end      % protocol: [0-0.49]
    a = abs(R.tauU);
    if a >= 0.80, tauBand = "very large"; elseif a >= 0.60, tauBand = "large";
    elseif a >= 0.20, tauBand = "moderate"; else, tauBand = "small"; end
    if R.NAP > 0.5
        interp = ternary(hib == 1, "improvement (higher under AR)", "higher under AR");
    elseif R.NAP < 0.5
        interp = ternary(hib == 1, "deterioration (lower under AR)", "lower under AR");
    else
        interp = "no difference";
    end
    if R.S_A == 0
        corrNote = "no baseline trend: Tau-U equals the uncorrected contrast";
    elseif R.S_B == 0
        corrNote = "no A-B difference: Tau-U here is the baseline trend alone";
    elseif R.tauU ~= 0 && sign(R.tauU) ~= sign(R.tauNO)
        corrNote = "Eq.1 REVERSES the sign: the baseline trend outweighs the A-B contrast";
    elseif abs(R.tauU) < abs(R.tauNO)
        corrNote = "baseline already trended the same way as the change: Eq.1 REDUCES the effect";
    else
        corrNote = "baseline trended the OPPOSITE way to the change: Eq.1 ENLARGES the effect";
    end
    if abs(R.tauU) > 1, corrNote = corrNote + "; |Tau-U| > 1, possible under Eq.1"; end
end

function s = joinNums(x, sep)
% Comma list of numbers; "" when there are none.
    if isempty(x), s = ""; else, s = strjoin(string(x(:)'), sep); end
end

function s = sgnStr(x)
    if x == 0, s = '0'; else, s = sprintf('%+d', x); end
end

function out = ternary(c,a,b), if c, out = a; else, out = b; end, end

function m = legMask(O, lg)
% Rows that carry a leg's values. "B" = a trial-level variable: s3a writes
% the same value on both rows of a trial, so the right-leg rows hold it.
    if lg == "B", m = O.leg == "R"; else, m = O.leg == lg; end
end

function s = legTitle(lg)
    if lg == "B"
        s = 'Both legs (one value per trial)';
    else
        s = sprintf('%s leg', ternary(lg == "L", 'Left', 'Right'));
    end
end

function checkTrialLevel(O, col)
% A trial-level variable must hold the same value on both rows of a trial.
    for k = unique(O.trial)'
        x = O.(col)(O.trial == k);
        x = x(isfinite(x));
        if numel(x) > 1 && max(x) - min(x) > 1e-9*max(1, max(abs(x)))
            error('Trial %d: %s differs between legs. Re-run s3a v3.', k, col);
        end
    end
end
