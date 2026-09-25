function cboard_imu_debug(comImu, comFpga)
%CBOARD_IMU_DEBUG Compare IMU and FPGA attitude frames in real time.
%
%   cboard_imu_debug
%   cboard_imu_debug("COM9", "COM15")
%
% Both ports use the v2.0 binary frame from Debug/serial_comm.md:
%   55 AA yaw_lo yaw_hi pitch_lo pitch_hi roll_lo roll_hi checksum 0D
% Angles are signed int16 values in Q2048 and are plotted in degrees.

    if nargin < 1 || isempty(comImu)
        comImu = "COM9";
    end
    if nargin < 2 || isempty(comFpga)
        comFpga = "COM15";
    end

    baudRate = 921600;
    historySeconds = 20;
    portNames = {char(string(comImu)), char(string(comFpga))};
    sourceNames = {'IMU直连', 'FPGA转发'};

    % Each parser has its own byte buffer because the two serial streams are
    % independent and may be split or coalesced at arbitrary byte boundaries.
    parserBuffer = {uint8([]), uint8([])};
    samples = struct('imu', emptyStream(), 'fpga', emptyStream());
    counters = struct('imu', emptyCounter(), 'fpga', emptyCounter());
    startTime = tic;

    fig = figure( ...
        'Name', 'IMU / FPGA 姿态对比', ...
        'NumberTitle', 'off', ...
        'Color', 'w', ...
        'MenuBar', 'none', ...
        'ToolBar', 'figure', ...
        'CloseRequestFcn', @closeFigure);

    ax = gobjects(3, 1);
    imuLine = gobjects(3, 1);
    fpgaLine = gobjects(3, 1);
    angleNames = {'Yaw', 'Pitch', 'Roll'};
    for k = 1:3
        ax(k) = subplot(3, 1, k, 'Parent', fig);
        hold(ax(k), 'on');
        grid(ax(k), 'on');
        box(ax(k), 'on');
        imuLine(k) = plot(ax(k), nan, nan, 'b-', 'LineWidth', 1.1, ...
            'DisplayName', sourceNames{1});
        fpgaLine(k) = plot(ax(k), nan, nan, 'r--', 'LineWidth', 1.1, ...
            'DisplayName', sourceNames{2});
        ylabel(ax(k), [angleNames{k} ' (deg)']);
        if k == 1
            title(ax(k), 'IMU 与 FPGA 转发姿态实时对比');
        end
        if k == 3
            xlabel(ax(k), '接收时间 (s)');
        end
        legend(ax(k), 'Location', 'best');
    end

    statusText = uicontrol(fig, ...
        'Style', 'text', ...
        'Units', 'normalized', ...
        'Position', [0.01 0.005 0.98 0.035], ...
        'HorizontalAlignment', 'left', ...
        'BackgroundColor', 'w', ...
        'ForegroundColor', [0.15 0.15 0.15], ...
        'String', '正在打开串口...');

    imuPort = [];
    fpgaPort = [];
    refreshTimer = [];
    try
        imuPort = openPort(portNames{1});
        fpgaPort = openPort(portNames{2});

        configureCallback(imuPort, 'byte', 1, @onImuBytes);
        configureCallback(fpgaPort, 'byte', 1, @onFpgaBytes);

        refreshTimer = timer( ...
            'ExecutionMode', 'fixedSpacing', ...
            'Period', 0.05, ...
            'BusyMode', 'drop', ...
            'TimerFcn', @refreshPlots);
        start(refreshTimer);
        updateStatus('已连接，等待姿态帧...');
    catch exception
        closeFigure([], []);
        rethrow(exception);
    end

    % Keep the function alive while the figure exists when called from the
    % command window; callbacks and the timer continue to run in the GUI.
    if nargout == 0 && isvalid(fig)
        uiwait(fig);
    end

    function port = openPort(portName)
        port = serialport(portName, baudRate);
        port.DataBits = 8;
        port.Parity = 'none';
        port.StopBits = 1;
        port.FlowControl = 'none';
        flush(port);
    end

    function onImuBytes(src, ~)
        consumeBytes(1, src);
    end

    function onFpgaBytes(src, ~)
        consumeBytes(2, src);
    end

    function consumeBytes(sourceIndex, src)
        try
            available = src.NumBytesAvailable;
            if available <= 0
                return;
            end
            incoming = read(src, available, 'uint8');
            parserBuffer{sourceIndex} = [parserBuffer{sourceIndex}, uint8(incoming(:).')]; %#ok<AGROW>
            [parserBuffer{sourceIndex}, frames, badChecksum, badTail] = ...
                decodeFrames(parserBuffer{sourceIndex});

            sourceField = sourceFieldName(sourceIndex);
            count = counters.(sourceField);
            count.checksum = count.checksum + badChecksum;
            count.tail = count.tail + badTail;
            count.valid = count.valid + size(frames, 1);
            counters.(sourceField) = count;

            if isempty(frames)
                return;
            end

            stream = samples.(sourceField);
            for frameIndex = 1:size(frames, 1)
                timestamp = toc(startTime);
                stream.time(end + 1) = timestamp; %#ok<AGROW>
                stream.yaw(end + 1) = frames(frameIndex, 1); %#ok<AGROW>
                stream.pitch(end + 1) = frames(frameIndex, 2); %#ok<AGROW>
                stream.roll(end + 1) = frames(frameIndex, 3); %#ok<AGROW>
            end

            keep = stream.time >= max(0, stream.time(end) - historySeconds);
            stream.time = stream.time(keep);
            stream.yaw = stream.yaw(keep);
            stream.pitch = stream.pitch(keep);
            stream.roll = stream.roll(keep);
            samples.(sourceField) = stream;
        catch exception
            updateStatus(sprintf('%s 读取错误: %s', sourceNames{sourceIndex}, exception.message));
        end
    end

    function refreshPlots(~, ~)
        if ~isvalid(fig)
            return;
        end

        imuData = samples.imu;
        fpgaData = samples.fpga;
        set(imuLine(1), 'XData', imuData.time, 'YData', imuData.yaw);
        set(imuLine(2), 'XData', imuData.time, 'YData', imuData.pitch);
        set(imuLine(3), 'XData', imuData.time, 'YData', imuData.roll);
        set(fpgaLine(1), 'XData', fpgaData.time, 'YData', fpgaData.yaw);
        set(fpgaLine(2), 'XData', fpgaData.time, 'YData', fpgaData.pitch);
        set(fpgaLine(3), 'XData', fpgaData.time, 'YData', fpgaData.roll);

        currentTime = toc(startTime);
        xStart = max(0, currentTime - historySeconds);
        xEnd = max(1, currentTime);
        for axisIndex = 1:3
            xlim(ax(axisIndex), [xStart, xEnd]);
        end

        updateStatus(sprintf( ...
            '%s: %d帧(校验错%d/帧尾错%d)    %s: %d帧(校验错%d/帧尾错%d)', ...
            sourceNames{1}, counters.imu.valid, counters.imu.checksum, counters.imu.tail, ...
            sourceNames{2}, counters.fpga.valid, counters.fpga.checksum, counters.fpga.tail));
        drawnow limitrate;
    end

    function updateStatus(message)
        if isvalid(statusText)
            statusText.String = message;
        end
    end

    function closeFigure(~, ~)
        if ~isempty(refreshTimer) && isvalid(refreshTimer)
            stop(refreshTimer);
            delete(refreshTimer);
            refreshTimer = [];
        end
        ports = {imuPort, fpgaPort};
        for portIndex = 1:numel(ports)
            if ~isempty(ports{portIndex}) && isvalid(ports{portIndex})
                configureCallback(ports{portIndex}, 'off');
            end
        end
        imuPort = [];
        fpgaPort = [];
        if isvalid(fig)
            uiresume(fig);
            delete(fig);
        end
    end

    function sourceField = sourceFieldName(sourceIndex)
        if sourceIndex == 1
            sourceField = 'imu';
        else
            sourceField = 'fpga';
        end
    end

    function stream = emptyStream()
        stream = struct('time', [], 'yaw', [], 'pitch', [], 'roll', []);
    end

    function count = emptyCounter()
        count = struct('valid', 0, 'checksum', 0, 'tail', 0);
    end
end

function [buffer, frames, badChecksum, badTail] = decodeFrames(buffer)
% Decode as many complete v2.0 frames as possible from a byte buffer.
    frames = zeros(0, 3);
    badChecksum = 0;
    badTail = 0;

    while true
        headerIndex = findHeader(buffer);
        if headerIndex == 0
            if ~isempty(buffer) && buffer(end) == uint8(hex2dec('55'))
                buffer = buffer(end);
            else
                buffer = uint8([]);
            end
            return;
        end

        if headerIndex > 1
            buffer(1:headerIndex - 1) = [];
        end
        if numel(buffer) < 10
            return;
        end

        candidate = buffer(1:10);
        checksum = mod(sum(double(candidate(3:8))), 256);
        if candidate(10) ~= uint8(hex2dec('0D'))
            badTail = badTail + 1;
            buffer(1) = [];
            continue;
        end
        if double(candidate(9)) ~= checksum
            badChecksum = badChecksum + 1;
            buffer(1) = [];
            continue;
        end

        yawRaw = decodeInt16LittleEndian(candidate(3), candidate(4));
        pitchRaw = decodeInt16LittleEndian(candidate(5), candidate(6));
        rollRaw = decodeInt16LittleEndian(candidate(7), candidate(8));
        frames(end + 1, :) = [yawRaw, pitchRaw, rollRaw] / 2048 * 180 / pi; %#ok<AGROW>
        buffer(1:10) = [];
    end
end

function index = findHeader(buffer)
    index = 0;
    if numel(buffer) < 2
        return;
    end
    match = find(buffer(1:end - 1) == uint8(hex2dec('55')) & ...
        buffer(2:end) == uint8(hex2dec('AA')), 1, 'first');
    if ~isempty(match)
        index = match;
    end
end

function value = decodeInt16LittleEndian(lowByte, highByte)
    value = double(lowByte) + 256 * double(highByte);
    if value >= 32768
        value = value - 65536;
    end
end
