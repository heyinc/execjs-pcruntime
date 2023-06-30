const vm = require('vm');
var contexts = {};
let context = vm.createContext();

/*
 * Versions of node before 0.12 (notably 0.10) didn't properly propagate
 * syntax errors.
 * This also regressed in the node 4.0 releases.
 *
 * To get around this, if it looks like we are missing the location of the
 * error, we guess it is (execjs):1
 *
 * This is obviously not ideal, but only affects syntax errors, and only on
 * these versions.
 */
function massageStackTrace(stack) {
  if (stack && stack.indexOf('SyntaxError') == 0) {
    return '(execjs):1\n' + stack;
  } else {
    return stack;
  }
}

function createContext() {
  var context = vm.createContext();
  vm.runInContext('delete console;', context, '(execjs prelude)');
  return context;
}

function getContext(uuid) {
  return contexts[uuid] || (contexts[uuid] = createContext());
}

var commands = {
  deleteContext: function (uuid) {
    delete contexts[uuid];
    return 1;
  },
  exit: function (code) {
    process.exit(code);
  },
  exec: function execJS(input) {
    var context = getContext(input.context);
    var source = input.source;
    try {
      var program = function () {
        return vm.runInContext(source, context, '(execjs)');
      };
      result = program();
      if (typeof result == 'undefined' && result !== null) {
        return ['ok'];
      } else {
        try {
          return ['ok', result];
        } catch (err) {
          return ['err', '' + err, err.stack];
        }
      }
    } catch (err) {
      return ['err', '' + err, massageStackTrace(err.stack)];
    }
  }
};

const http = require('http');
const server = http.createServer(function (req, res) {
  switch (req.url) {
    case '/':
      res.statusCode = 200;
      res.end();
      break;
    case '/eval':
      let allData = '';
      req.on('data', (data) => allData += data);
      req.on('end', () => {
        try {
          const result = vm.runInContext(allData, context);
          res.statusCode = 200;
          res.setHeader('Content-Type', 'application/json');
          res.end(JSON.stringify(result), 'utf-8');
        } catch (e) {
          res.statusCode = 500;
          res.setHeader('Content-Type', 'text/plain');
          res.end(e.toString());
        }
      });
      break;
    case '/exit':
      process.exit(0);
      break;
    default:
      console.log("Unknown Path");
      break;
  }
});

const port = process.env.PORT || 3001;
server.listen(port);
