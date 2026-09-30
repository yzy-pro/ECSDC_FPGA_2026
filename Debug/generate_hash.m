% Calculate a SHA-256 digest for lut.bin and write it to lut_checksum.bin.

scriptDirectory = fileparts(mfilename('fullpath'));
inputPath = fullfile(scriptDirectory, 'lut.bin');
outputPath = fullfile(scriptDirectory, 'lut_checksum.bin');

inputFile = fopen(inputPath, 'rb');
assert(inputFile ~= -1, 'Unable to open input file: %s', inputPath);
lutBytes = fread(inputFile, Inf, '*uint8');
fclose(inputFile);

sha256 = java.security.MessageDigest.getInstance('SHA-256');
sha256.update(typecast(lutBytes, 'int8'));
checksum = typecast(sha256.digest(), 'uint8');

outputFile = fopen(outputPath, 'wb', 'ieee-le');
assert(outputFile ~= -1, 'Unable to open output file: %s', outputPath);
fwrite(outputFile, checksum, 'uint8');
fclose(outputFile);

checksumText = lower(reshape(dec2hex(checksum, 2).', 1, []));
fprintf('SHA-256: %s\n', checksumText);
fprintf('Wrote %d bytes to %s\n', numel(checksum), outputPath);
