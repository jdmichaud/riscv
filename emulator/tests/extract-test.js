fs = require('fs');

tmp = fs.readFileSync('testcases.jsonlines').toString();
const testCases = JSON.parse(tmp);
const testCaseMap = {};
testCases.forEach(testCase => {
  const instruction = testCase.text_encoding.split(' ')[0]
  if (testCaseMap[instruction] === undefined) {
    testCaseMap[instruction] = [testCase]; } else { testCaseMap[instruction].push(testCase);
  }
});
Object.keys(testCaseMap).forEach(key => fs.writeFileSync(`json/${key}.json`, JSON.stringify(testCaseMap[key])));
