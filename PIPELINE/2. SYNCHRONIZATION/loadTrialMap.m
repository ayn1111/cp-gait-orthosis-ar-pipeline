function M = loadTrialMap(csvPath)
% loadTrialMap  Read TRIALMAP_<P>.csv with column types forced correctly.
%
% WHY THIS EXISTS
%   readtable() guesses column types from content. Several trial-map columns
%   hold values that LOOK numeric but are identifiers:
%
%       gaitup_day  20260824   <- a date used as a FOLDER NAME
%
%   readtable imports that as a double, and char(20260824) then yields a
%   single garbage Unicode character rather than "20260824". Every path built
%   from it points nowhere, and because the failure is a missing file rather
%   than an error, the calling script carries on and silently produces nothing.
%
%   This will happen on any patient whose filenames are purely numeric, so the
%   fix belongs in one place that every script calls.
%
% USAGE
%   M = loadTrialMap(TrialMapCsv);
%   day = char(M.gaitup_day(i));     % always a proper string now
%
% RETURNS
%   trial, session            double
%   everything else           string
%
% Put this file anywhere on the MATLAB path, or in the same folder as the
% s1/s2 scripts.

    if ~isfile(csvPath)
        error('loadTrialMap:notFound', 'Trial map not found:\n  %s', csvPath);
    end

    opts = detectImportOptions(csvPath, 'TextType', 'string');

    % Force every column that is an identifier, a filename or a label to string,
    % whatever its content looks like.
    textCols = {'date','condition','inGAIT_file','EMG_file','IMU_file', ...
                'gaitup_day','gaitup_LF','gaitup_RF','notes'};
    textCols = intersect(textCols, opts.VariableNames);
    if ~isempty(textCols)
        opts = setvartype(opts, textCols, 'string');
    end

    % Keep the two genuinely numeric columns numeric.
    numCols = intersect({'trial','session'}, opts.VariableNames);
    if ~isempty(numCols)
        opts = setvartype(opts, numCols, 'double');
    end

    M = readtable(csvPath, opts);

    % ---- structural checks: fail loudly here rather than silently later ----
    need = {'trial','session','inGAIT_file','EMG_file','IMU_file'};
    miss = setdiff(need, M.Properties.VariableNames);
    if ~isempty(miss)
        error('loadTrialMap:missingColumns', ...
              'Trial map is missing required column(s): %s', strjoin(miss,', '));
    end
    if height(M) == 0
        error('loadTrialMap:empty', 'Trial map has no rows: %s', csvPath);
    end
    if numel(unique(M.trial)) ~= height(M)
        error('loadTrialMap:duplicateTrials', ...
              'Trial numbers are not unique in %s', csvPath);
    end

    % A numeric-looking value that survived as a number would break path building.
    for c = string(textCols)
        if ~isstring(M.(c))
            error('loadTrialMap:typeFailure', ...
                  'Column %s did not import as text. Check the CSV.', c);
        end
    end
end
