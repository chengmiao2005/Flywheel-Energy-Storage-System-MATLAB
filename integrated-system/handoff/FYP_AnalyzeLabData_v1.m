function [series, summary, outputDir] = FYP_AnalyzeLabData_v1(csvFile, confirmedJ)
%FYP_ANALYZELABDATA_V1 Analyze real, synchronized FESS branch measurements.
% [series, summary, outputDir] = FYP_AnalyzeLabData_v1(csvFile, confirmedJ)
% Required CSV columns (SI units, no default hardware parameters):
%   time_s, V_bus_V, I_fess_bus_A, n_rpm
% Positive I_fess_bus_A flows from the DC bus INTO the entire FESS branch.
% confirmedJ is the independently confirmed rotor + flywheel inertia (kg*m^2).
% Measure branch current, not total source or traction current. Correct sensor
% offsets and align channels before use. Raw input is never overwritten.
% No round-trip efficiency is claimed without a complete matched-state cycle.

    narginchk(2, 2);
    validateattributes(confirmedJ, {'numeric'}, ...
        {'scalar', 'real', 'finite', 'positive'}, mfilename, 'confirmedJ');
    confirmedJ = double(confirmedJ);
    assert(ischar(csvFile) || (isstring(csvFile) && isscalar(csvFile)), ...
        'FYP:InputPath', 'csvFile must be a character vector or string scalar.');
    csvFile = char(csvFile);
    assert(isfile(csvFile), 'FYP:MissingInput', 'Input CSV does not exist: %s', csvFile);
    raw = readtable(csvFile, 'VariableNamingRule', 'preserve');
    required = {'time_s', 'V_bus_V', 'I_fess_bus_A', 'n_rpm'};
    assert(all(ismember(required, raw.Properties.VariableNames)), ...
        'FYP:Columns', 'Required columns: time_s, V_bus_V, I_fess_bus_A, n_rpm');
    assert(height(raw) >= 3, 'FYP:TooShort', 'At least three synchronized samples are required.');
    for k = 1:numel(required)
        value = raw.(required{k});
        validateattributes(value, {'numeric'}, {'column', 'real', 'finite'}, ...
            mfilename, required{k});
    end
    time = double(raw.time_s);
    voltage = double(raw.V_bus_V);
    current = double(raw.I_fess_bus_A);
    rpm = double(raw.n_rpm);
    assert(all(diff(time) > 0), 'FYP:TimeOrder', 'time_s must increase strictly.');
    assert(all(voltage >= 0), 'FYP:VoltageSign', 'This DC-bus convention requires nonnegative V_bus_V.');
    assert(all(rpm >= 0), 'FYP:SpeedSign', 'This analysis assumes positive-direction operation.');

    elapsed = time - time(1);
    power = voltage .* current;
    [energyIn, energyOut] = splitLinearPower(elapsed, power);
    rotor = 0.5 * confirmedJ * (rpm * (2*pi/60)).^2;
    deltaRotor = rotor - rotor(1);
    netInput = energyIn - energyOut;
    balanceGap = netInput - deltaRotor;
    integrationError = max(abs(netInput - cumtrapz(elapsed, power)));
    tolerance = 1e-9 * max(1, energyIn(end) + energyOut(end));
    assert(integrationError <= tolerance, 'FYP:IntegralIdentity', ...
        'Signed power integral does not match imported minus returned energy.');

    series = table(time, elapsed, voltage, current, rpm, power, ...
        energyIn, energyOut, rotor, deltaRotor, netInput, balanceGap, ...
        'VariableNames', {'time_s', 'elapsed_s', 'V_bus_V', 'I_fess_bus_A', ...
        'n_rpm', 'P_fess_bus_W', 'E_import_J', 'E_return_J', 'E_rotor_J', ...
        'Delta_E_rotor_J', 'Net_input_J', 'Net_input_minus_rotor_change_J'});
    summary = struct();
    summary.input_csv = csvFile;
    summary.sample_count = height(raw);
    summary.duration_s = elapsed(end);
    summary.dt_min_s = min(diff(time));
    summary.dt_median_s = median(diff(time));
    summary.dt_max_s = max(diff(time));
    summary.confirmed_total_inertia_kg_m2 = confirmedJ;
    summary.imported_J = energyIn(end);
    summary.returned_J = energyOut(end);
    summary.net_input_J = netInput(end);
    summary.rotor_change_J = deltaRotor(end);
    summary.net_input_minus_rotor_change_J = balanceGap(end);
    summary.signed_integral_identity_error_J = integrationError;
    summary.initial_rpm = rpm(1);
    summary.final_rpm = rpm(end);
    summary.current_sign = 'Positive means DC bus into the complete FESS branch.';
    summary.integration = 'Piecewise-linear sampled power, split at zero crossings; no hidden smoothing.';
    summary.interpretation = ['Net input minus rotor change also includes internal electrical stored-energy changes ' ...
        'and measurement error; it is not by itself a complete measured loss. No round-trip efficiency is reported.'];

    [parent, ~, ~] = fileparts(csvFile);
    if isempty(parent)
        parent = pwd;
    end
    stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss_SSS'));
    outputDir = fullfile(parent, ['LabAnalysis_' stamp]);
    assert(~isfolder(outputDir), 'FYP:OutputExists', 'Choose a new output folder.');
    [ok, message] = mkdir(outputDir);
    assert(ok, 'FYP:OutputFolder', '%s', message);
    writetable(series, fullfile(outputDir, 'energy_timeseries.csv'));
    fid = fopen(fullfile(outputDir, 'summary.json'), 'w', 'n', 'UTF-8');
    assert(fid >= 0, 'FYP:WriteSummary', 'Cannot open summary output.');
    closeFile = onCleanup(@() fclose(fid));
    fprintf(fid, '%s\n', jsonencode(summary, 'PrettyPrint', true));
    clear closeFile;
    save(fullfile(outputDir, 'analysis.mat'), 'series', 'summary');

    fig = figure('Name', 'Measured FESS branch analysis', 'Color', 'w', ...
        'Position', [100 100 1150 780]);
    layout = tiledlayout(fig, 2, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
    nexttile(layout);
    plot(elapsed, power); grid on; xlabel('Time / s'); ylabel('Branch power / W');
    title('Positive: bus into FESS');
    nexttile(layout);
    plot(elapsed, rpm); grid on; xlabel('Time / s'); ylabel('Speed / rpm');
    title('Measured speed');
    nexttile(layout);
    plot(elapsed, [energyIn energyOut deltaRotor]); grid on;
    xlabel('Time / s'); ylabel('Energy / J');
    legend('Imported', 'Returned', 'Rotor change', 'Location', 'best');
    nexttile(layout);
    plot(elapsed, balanceGap); grid on; xlabel('Time / s'); ylabel('Energy / J');
    title('Net input minus rotor change (not full loss)');
    exportgraphics(fig, fullfile(outputDir, 'measured_energy.png'), 'Resolution', 180);
    savefig(fig, fullfile(outputDir, 'measured_energy.fig'));
    fprintf('Lab analysis saved: %s\n', outputDir);
    fprintf('Input %.6f J; return %.6f J; rotor change %.6f J.\n', ...
        summary.imported_J, summary.returned_J, summary.rotor_change_J);
end

function [energyIn, energyOut] = splitLinearPower(time, power)
% Exact positive/negative integrals of the piecewise-linear sampled power.
% Splitting a crossing avoids trapezoidal overcount from max(power,0).
    count = numel(time);
    energyIn = zeros(count, 1);
    energyOut = zeros(count, 1);
    for k = 2:count
        dt = time(k) - time(k-1);
        a = power(k-1);
        b = power(k);
        if a >= 0 && b >= 0
            positive = 0.5 * (a+b) * dt;
            negative = 0;
        elseif a <= 0 && b <= 0
            positive = 0;
            negative = -0.5 * (a+b) * dt;
        else
            crossing = abs(a) / (abs(a) + abs(b));
            areaBefore = 0.5 * abs(a) * dt * crossing;
            areaAfter = 0.5 * abs(b) * dt * (1-crossing);
            if a > 0
                positive = areaBefore;
                negative = areaAfter;
            else
                positive = areaAfter;
                negative = areaBefore;
            end
        end
        energyIn(k) = energyIn(k-1) + positive;
        energyOut(k) = energyOut(k-1) + negative;
    end
end
