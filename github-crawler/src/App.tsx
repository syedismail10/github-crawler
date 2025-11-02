import { useEffect, useState } from "react";
import axios from "axios";

function RepoTable({ items }: { items: any[] }) {
  return (
    <div className="bg-white shadow-md rounded-lg overflow-hidden">
      <table className="min-w-full divide-y divide-gray-200">
        <thead className="bg-gray-50">
          <tr>
            <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Repository
            </th>
            <th className="px-6 py-3 text-right text-xs font-medium text-gray-500 uppercase tracking-wider">
              Stars
            </th>
            <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
              Snapshot
            </th>
          </tr>
        </thead>
        <tbody className="bg-white divide-y divide-gray-200">
          {items.map((r) => (
            <tr
              key={r.repo_node_id}
              className="hover:bg-gray-50 transition duration-150"
            >
              <td className="px-6 py-4 whitespace-nowrap text-sm text-blue-600 hover:text-blue-800">
                <a
                  href={r.url}
                  target="_blank"
                  rel="noreferrer"
                  className="font-medium"
                >
                  {r.name_with_owner}
                </a>
              </td>
              <td className="px-6 py-4 whitespace-nowrap text-sm text-right font-semibold text-gray-900">
                {r.stars.toLocaleString()}
              </td>
              <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                {r.snapshot_date}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export default function App() {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(false);
  const [target, setTarget] = useState(100);
  const [page, setPage] = useState(1);
  const [total, setTotal] = useState(0);
  const limit = 50;

  useEffect(() => {
    fetchRepos(page);
  }, [page]);

  async function fetchRepos(pageNum: number) {
    setLoading(true);
    try {
      const offset = (pageNum - 1) * limit;
      const data = await axios.get(
        `http://localhost:8000/api/repos?limit=${limit}&offset=${offset}`
      );
      setItems(data.data.items || []);
      setTotal(data.data.total || 0);
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  }

  async function triggerCrawl() {
    const data = await axios.post("http://localhost:8000/api/crawl", {
      target: Number(target),
    });
    alert("Crawl started (pid=" + data.data.pid + ")");
  }

  const totalPages = Math.ceil(total / limit);

  return (
    <div className="min-h-screen bg-gray-50 py-8">
      <div className="max-w-6xl mx-auto px-4">
        <h1 className="text-3xl font-bold text-gray-900 mb-6 text-center">
          GitHub Stars UI
        </h1>

        <div className="bg-white shadow-md rounded-lg p-6 mb-6">
          <div className="flex flex-col sm:flex-row gap-4 items-center">
            <div className="flex items-center gap-2">
              <label className="text-sm font-medium text-gray-700">
                Target:
              </label>
              <input
                className="border border-gray-300 rounded-md px-3 py-2 focus:outline-none focus:ring-2 focus:ring-blue-500"
                type="number"
                value={target}
                onChange={(e) => setTarget(Number(e.target.value))}
              />
            </div>
            <button
              className="bg-blue-600 hover:bg-blue-700 text-white px-4 py-2 rounded-md transition duration-200"
              onClick={triggerCrawl}
            >
              Trigger Crawl
            </button>
            <button
              className="bg-gray-200 hover:bg-gray-300 text-gray-800 px-4 py-2 rounded-md transition duration-200 ml-auto"
              onClick={() => fetchRepos(page)}
            >
              Refresh
            </button>
          </div>
        </div>

        {loading ? (
          <div className="text-center py-8">
            <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600 mx-auto"></div>
            <p className="mt-4 text-gray-600">Loading...</p>
          </div>
        ) : (
          <>
            <RepoTable items={items} />
            <div className="mt-6 flex justify-between items-center">
              <button
                className="bg-gray-200 hover:bg-gray-300 text-gray-800 px-4 py-2 rounded-md disabled:opacity-50 disabled:cursor-not-allowed transition duration-200"
                onClick={() => setPage(Math.max(1, page - 1))}
                disabled={page === 1}
              >
                Previous
              </button>
              <span className="text-sm text-gray-600">
                Page {page} of {totalPages} ({total} total repos)
              </span>
              <button
                className="bg-gray-200 hover:bg-gray-300 text-gray-800 px-4 py-2 rounded-md disabled:opacity-50 disabled:cursor-not-allowed transition duration-200"
                onClick={() => setPage(Math.min(totalPages, page + 1))}
                disabled={page === totalPages}
              >
                Next
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}
