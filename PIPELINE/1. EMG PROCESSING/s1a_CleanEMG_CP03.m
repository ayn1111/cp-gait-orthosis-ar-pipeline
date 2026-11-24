% s1a_CleanEMG_CP03.m
% =========================================================================
% STAGE 1, STEP 1 of 4.
%
% WHAT THIS PROCESSES
%   The 30 raw Delsys EMG CSVs in PAC03\RAW\EMG (timestamp_ns + emg1..emg8).
%
% WHY IT EXISTS
%   Three of the 30 recordings were written with NUL (0x00) padding instead of
%   data, because the recorder was interrupted mid-write:
%       emg_20260826_190257.csv   53.8 MB of NULs   -> only  69.2 s of real EMG
%       emg_20260831_190345.csv   ~40  MB of NULs   -> only 114.8 s of real EMG
%       emg_20260831_191231.csv   89.5 MB of NULs   -> ZERO rows of real EMG
%   readtable() on these either throws or returns garbage rows. Rather than
%   special-casing them later, we clean all 30 uniformly here.
%
% WHAT IT ACHIEVES
%   PAC03\PROCESSED\EMG_CLEAN\*.csv   - 30 guaranteed-parseable CSVs
%   PAC03\PROCESSED\EMG_INTEGRITY.csv - per-file report: rows kept, NULs found,
%                                       duration, sample rate, monotonicity
%
%   After this step, nothing downstream reads PAC03\RAW\EMG.
%
% RUNTIME: ~3-6 minutes for 2.3 GB of CSV. Run it once.
% =========================================================================

clear; clc;

% ===== USER SETTINGS - edit these three paths only =====
SourcePath = 'C:\INVESTIGACION CSIC\PAC03\RAW\EMG';
CleanPath  = 'C:\INVESTIGACION CSIC\PAC03\PROCESSED\EMG_CLEAN';
ReportCsv  = 'C:\INVESTIGACION CSIC\PAC03\PROCESSED\EMG_INTEGRITY.csv';
% =======================================================

EXPECTED_FS = 2000;          % Delsys device rate, for the sanity check
CHUNK       = 32e6;          % bytes per read; keeps memory flat on 160 MB files

if ~exist(CleanPath,'dir'), mkdir(CleanPath); end
rp = fileparts(ReportCsv);
if ~isempty(rp) && ~exist(rp,'dir'), mkdir(rp); end

d = dir(fullfile(SourcePath,'emg_*.csv'));
if isempty(d), error('No emg_*.csv found in %s', SourcePath); end
[~,ord] = sort({d.name});    % date-time stamped names -> name sort = chronological
d = d(ord);

fprintf('Cleaning %d EMG files\n', numel(d));
fprintf('%-28s %10s %10s %10s %9s %9s  %s\n', ...
        'file','bytes_in','NUL_MB','rows','dur_s','fs_Hz','status');
fprintf('%s\n', repmat('-',1,95));

R = table('Size',[numel(d) 8], ...
    'VariableTypes',{'string','double','double','double','double','double','double','string'}, ...
    'VariableNames',{'file','bytes_in','nul_bytes','rows','dur_s','fs_hz','nonmono','status'});

for i = 1:numel(d)
    src = fullfile(d(i).folder, d(i).name);
    dst = fullfile(CleanPath,   d(i).name);

    % ---- Pass 1: strip NULs, keep only complete lines --------------------
    fin  = fopen(src,'r');
    if fin < 0, error('Cannot open %s', src); end
    fout = fopen(dst,'w');
    if fout < 0, fclose(fin); error('Cannot write %s', dst); end

    carry   = uint8([]);
    nNul    = 0;
    while true
        buf = fread(fin, CHUNK, '*uint8');
        if isempty(buf) && isempty(carry), break; end
        if ~isempty(buf)
            z    = (buf == 0);
            nNul = nNul + nnz(z);
            buf(z) = [];                       % drop NUL bytes
        end
        buf = [carry; buf];                    %#ok<AGROW> prepend leftover
        nl  = find(buf == 10, 1, 'last');      % last complete newline
        if isempty(nl)
            carry = buf;
        else
            fwrite(fout, buf(1:nl));
            carry = buf(nl+1:end);             % partial line -> next round
        end
        if feof(fin), break; end
    end
    % Anything still in carry is an INCOMPLETE final line. Discard it: that is
    % precisely the half-written row at the truncation point.
    fclose(fin); fclose(fout);

    % ---- Pass 2: validate the cleaned file -------------------------------
    status = "ok";
    nRows = 0; dur = NaN; fs = NaN; nonmono = 0;
    try
        T = readtable(dst, 'Delimiter', ',', 'TextType','string');
        nRows = height(T);
        if nRows < 2
            status = "EMPTY - no usable EMG";
        else
            ts  = double(T.timestamp_ns);
            dur = (ts(end) - ts(1)) * 1e-9;
            fs  = (nRows - 1) / dur;
            nonmono = nnz(diff(ts) <= 0);
            if nonmono > 0
                status = sprintf("%d non-monotonic timestamps", nonmono);
            elseif abs(fs - EXPECTED_FS) > 0.02*EXPECTED_FS
                status = sprintf("fs %.1f Hz, expected %d", fs, EXPECTED_FS);
            elseif nNul > 0
                status = "TRUNCATED but clean";
            end
        end
    catch ME
        status = "READ FAILED: " + string(ME.message);
    end

    fprintf('%-28s %10.0f %10.1f %10d %9.1f %9.2f  %s\n', ...
            d(i).name, d(i).bytes, nNul/1e6, nRows, dur, fs, status);

    R(i,:) = {string(d(i).name), d(i).bytes, nNul, nRows, dur, fs, nonmono, status};
end

writetable(R, ReportCsv);
fprintf('\nSaved integrity report -> %s\n', ReportCsv);

% ---- Summary of what needs attention ------------------------------------
bad = R(R.nul_bytes > 0 | R.rows < 2 | R.nonmono > 0, :);
if isempty(bad)
    fprintf('All %d files clean.\n', height(R));
else
    fprintf('\n%d file(s) need attention:\n', height(bad));
    disp(bad(:,{'file','nul_bytes','rows','dur_s','status'}));
    fprintf(['These stay in the pipeline. Step 1.3 clips their analysis window\n' ...
             'to the EMG that actually exists; step 1.4 skips any file with 0 rows.\n']);
end
